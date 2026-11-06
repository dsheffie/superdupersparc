#include <cstdio>
#include <cstring>
#include <fstream>
#include <boost/archive/binary_oarchive.hpp>
#include <boost/archive/binary_iarchive.hpp>
#include <boost/serialization/binary_object.hpp>
#include <boost/serialization/map.hpp>
#include <boost/serialization/vector.hpp>

#include "ckpt.hh"
#include "interpret.hh"
#include "sun4m.hh"

/* bump when any serialized layout below changes */
static const uint32_t CKPT_VERSION = 1;
static const uint64_t CKPT_MAGIC = 0x54504b4330315353ULL;   /* "SS10CKPT" */

namespace boost {
namespace serialization {

template <class A> void serialize(A &ar, escc_t::chn_t &c, unsigned) {
  ar & c.wregs & c.rregs & c.reg & c.rx & c.tx & c.rxint & c.txint & c.rxint_under_svc & c.txint_under_svc;
}
template <class A> void serialize(A &ar, escc_t &e, unsigned) {
  ar & e.chn & e.disabled & e.console & e.irq;
}
template <class A> void serialize(A &ar, intctl_t &i, unsigned) {
  ar & i.slave_pending & i.irl_out & i.master_pending & i.master_disabled & i.target_cpu;
}
template <class A> void serialize(A &ar, fdc_t &f, unsigned) {
  ar & f.sra & f.srb & f.dor & f.msr & f.dsr & f.status0 & f.fifo & f.pos & f.len & f.phase & f.reset_sensei;
  ar & f.timer0 & f.timer1 & f.config & f.precomp & f.lock & f.perpendicular & f.irq;
}
template <class A> void serialize(A &ar, slavio_ctr_t &c, unsigned) {
  ar & c.limit & c.start_ns & c.next_ns & c.ubase & c.count & c.counthigh & c.reached & c.run & c.on & c.irq;
}
template <class A> void serialize(A &ar, sparc_dma_t &d, unsigned) {
  ar & d.r & d.irq;
}
template <class A> void serialize(A &ar, esp_t &e, unsigned) {
  ar & e.rregs & e.wregs & e.fifo & e.fifo_n & e.tchi_written & e.dma & e.dma_enabled & e.satn_pending & e.irq;
}
template <class A> void serialize(A &ar, fw_cfg_t &f, unsigned) {
  ar & f.items & f.cur & f.off;
}
template <class A> void serialize(A &ar, sun4m_t &m, unsigned) {
  ar & m.fw_cfg & m.espdma & m.ledma & m.esp & m.intctl & m.ctr & m.ctr_user_mode;
  ar & m.ns_shift & m.next_event_icnt & m.next_event_ns & m.time_bias_ns & m.cpu_halted & m.rtc_base & m.reset_req;
  ar & m.kbd_ms & m.serial & m.aux1 & m.aux2 & m.diag & m.mdm & m.fdc & m.leds & m.sysctrl;
  ar & make_binary_object(m.prom, sizeof(m.prom));
  ar & m.nvram & m.iommu & m.ecc;
}
/* the architectural state (not the memory, the device pointer or the halt flags) */
template <class A> void serialize(A &ar, state_t &s, unsigned) {
  ar & s.pc & s.npc & s.r & s.icc_n & s.icc_z & s.icc_v & s.icc_c & s.ef & s.s & s.ps & s.et;
  ar & s.pil & s.cwp & s.wim & s.tbr & s.y & s.asr & s.f & s.fsr & s.fq_addr & s.fq_insn;
  ar & s.mmu_ctrl & s.mmu_ctpr & s.mmu_ctx & s.mmu_fsr & s.mmu_far & s.mxcc & s.mxccdata;
  ar & s.ram_size & s.irl & s.icnt & s.ntraps & s.user_emu;
}

} // namespace serialization
} // namespace boost

static bool page_is_zero(const uint8_t *p) {
  for(uint64_t i = 0; i < sparse_mem::pgsize; i += 8) {
    uint64_t w;
    memcpy(&w, p + i, 8);
    if(w != 0) {
      return false;
    }
  }
  return true;
}

bool save_checkpoint(const char *fn, const state_t *s) {
  std::ofstream out(fn, std::ios::binary);
  if(not out) {
    fprintf(stderr, "checkpoint: cannot write %s\n", fn);
    return false;
  }
  boost::archive::binary_oarchive ar(out);
  state_t &st = const_cast<state_t &>(*s);
  uint64_t magic = CKPT_MAGIC;
  uint32_t version = CKPT_VERSION;
  bool has_sun4m = (s->sun4m != nullptr);
  ar & magic & version & st & has_sun4m;
  if(has_sun4m) {
    ar & *st.sun4m;
  }
  /* RAM: the non-zero pages below ram_size (all 4GB without devices) */
  uint64_t top = std::min<uint64_t>(s->ram_size, sparse_mem::sz);
  std::vector<uint32_t> pages;
  for(uint64_t pa = 0; pa < top; pa += sparse_mem::pgsize) {
    if(not page_is_zero(st.mem.mem + pa)) {
      pages.push_back(static_cast<uint32_t>(pa / sparse_mem::pgsize));
    }
  }
  ar & pages;
  for(uint32_t pg : pages) {
    ar & boost::serialization::make_binary_object(st.mem.mem + static_cast<uint64_t>(pg) * sparse_mem::pgsize,
						  sparse_mem::pgsize);
  }
  fprintf(stderr, "checkpoint: wrote %s at icnt %llu pc 0x%x (%zu RAM pages)\n", fn,
	  static_cast<unsigned long long>(s->icnt), s->pc, pages.size());
  return true;
}

bool load_checkpoint(const char *fn, state_t *s) {
  std::ifstream in(fn, std::ios::binary);
  if(not in) {
    fprintf(stderr, "checkpoint: cannot read %s\n", fn);
    return false;
  }
  boost::archive::binary_iarchive ar(in);
  uint64_t magic = 0;
  uint32_t version = 0;
  ar & magic & version;
  if(magic != CKPT_MAGIC or version != CKPT_VERSION) {
    fprintf(stderr, "checkpoint: %s is not a version %u checkpoint\n", fn, CKPT_VERSION);
    return false;
  }
  bool has_sun4m = false;
  ar & *s & has_sun4m;
  if(has_sun4m) {
    if(s->sun4m == nullptr) {
      s->sun4m = new sun4m_t();
    }
    ar & *s->sun4m;
  }
  s->mem.clear();
  std::vector<uint32_t> pages;
  ar & pages;
  for(uint32_t pg : pages) {
    ar & boost::serialization::make_binary_object(s->mem.mem + static_cast<uint64_t>(pg) * sparse_mem::pgsize,
						  sparse_mem::pgsize);
  }
  fprintf(stderr, "checkpoint: restored %s at icnt %llu pc 0x%x (%zu RAM pages)\n", fn,
	  static_cast<unsigned long long>(s->icnt), s->pc, pages.size());
  return true;
}
