#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <boost/program_options.hpp>

#include "interpret.hh"
#include "sun4m.hh"
#include "loadelf.hh"
#include "disassemble.hh"
#include "helper.hh"
#include "globals.hh"

/* Standalone SPARC V8 ISS driver: run an ELF, optionally under Linux user-mode
 * syscall/window emulation (--user) so the same static binary can be diffed
 * against qemu-sparc. */

namespace globals {
  bool enClockFuncts = false;
  uint64_t icountMIPS = 0;
  uint64_t cycle = 0;
  bool trace_retirement = false;
  bool trace_fp = false;
  bool report_syscalls = false;
  bool ip28 = false;
};

int main(int argc, char *argv[]) {
  namespace po = boost::program_options;
  std::string filename, rom, nvram, pctrace;
  uint32_t ram_mb = 256;
  uint64_t max_icnt = ~0ULL;
  bool user = false, trace = false, dump = false, with_sun4m = false;
  try {
    po::options_description desc("Options");
    desc.add_options()
      ("help", "print help")
      ("file,f", po::value<std::string>(&filename), "sparc elf binary")
      ("rom,r", po::value<std::string>(&rom), "sun4m (SS-20) boot prom image: reset into it instead of an elf")
      ("ram", po::value<uint32_t>(&ram_mb), "sun4m RAM size in MB (with --rom)")
      ("nvram", po::value<std::string>(&nvram), "sun4m M48T08 nvram image (with --rom)")
      ("sun4m", po::bool_switch(&with_sun4m), "run the elf with the sun4m devices attached (RAM = --ram)")
      ("pctrace", po::value<std::string>(&pctrace), "write every executed pc (hex, one per line) to this file")
      ("maxicnt,m", po::value<uint64_t>(&max_icnt), "max instructions to execute")
      ("user,u", po::bool_switch(&user), "linux user-mode emulation (syscalls + window spill/fill)")
      ("trace,t", po::bool_switch(&trace), "print every executed instruction")
      ("dump,d", po::bool_switch(&dump), "dump register state at exit");
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);
    if(vm.count("help") or (filename.empty() and rom.empty())) {
      std::cout << desc << "\n";
      return 1;
    }
  }
  catch(po::error &e) {
    std::cerr << "command line error : " << e.what() << "\n";
    return 1;
  }

  sparse_mem mem;
  state_t *s = new state_t(mem);
  s->user_emu = user;
  initState(s);
  if(not rom.empty()) {
    /* sun4m power-on: PC 0 / nPC 4 in Viking boot mode; WIM=1 and PS=1 as qemu
     * resets them (architecturally undefined), so traces line up */
    s->sun4m = new sun4m_t();
    if(not s->sun4m->load_prom(rom.c_str())) {
      return 1;
    }
    if(not nvram.empty() and not s->sun4m->load_nvram(nvram.c_str())) {
      return 1;
    }
    s->ram_size = static_cast<uint64_t>(ram_mb) << 20;
    s->mmu_ctrl |= MCR_BMODE;
    s->pc = 0;
    s->npc = 4;
    s->wim = 1;
    s->ps = true;
  }
  else {
    load_elf(filename.c_str(), s);
    if(with_sun4m) {
      s->sun4m = new sun4m_t();
      s->ram_size = static_cast<uint64_t>(ram_mb) << 20;
    }
  }
  FILE *pcfp = pctrace.empty() ? nullptr : fopen(pctrace.c_str(), "w");
  if(trace) {
    initCapstone();
  }

  while(not s->brk and s->icnt < max_icnt) {
    if(pcfp) {
      fprintf(pcfp, "%08x\n", s->pc);
    }
    if(trace) {
      uint32_t inst = __builtin_bswap32(mem.get<uint32_t>(s->pc));
      fprintf(stderr, "%08x %08x cwp %u : %s\n", s->pc, inst, s->cwp, getAsmString(inst, s->pc).c_str());
    }
    execSparc(s);
  }

  if(dump) {
    std::cerr << *s;
  }
  std::cerr << "ISS: " << s->icnt << " insns, exit code " << s->exit_code
	    << (s->error_mode ? " (error mode)" : "") << "\n";
  if(trace) {
    stopCapstone();
  }
  if(pcfp) {
    fclose(pcfp);
  }
  int rc = s->exit_code;
  delete s;
  return rc;
}
