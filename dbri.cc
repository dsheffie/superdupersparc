/* The SS-20's onboard DBRI (SUNW,DBRIe@e,10000): the ISDN/audio controller's
 * command and interrupt queues, enough for a driver to bring the chip up with
 * no codec attached.  Register and command semantics follow Linux
 * sound/sparc/dbri.c (written from the DBRI manual).
 *
 * Why it exists: NeXTSTEP's SunAudio driver (SunAudio_reloc, dbri_command)
 * reads REG8 -- the chip's command-queue pointer, which it advances as it
 * executes -- and panics "DBRI Reg8 bad!" unless it lies inside the driver's
 * 512-word queue; it also measures free queue space from it.  With the
 * registers unmodeled (reads 0) every NeXTSTEP boot panicked into the mini
 * monitor right after "Using Default table for SunAudio".
 *
 * Modeled:
 *   REG0  status/control: D_R (soft reset) completes at once; D_P (re-read the
 *         command at REG8) runs the queue and reads back clear.
 *   REG1  mode/interrupt: reads D_IR while an interrupt is pending; the read
 *         clears it (the chip's interrupt indicator).
 *   REG2  parallel I/O: the written enables/outputs; the PIO inputs read 0, so
 *         no codec is detected (an SS-20 with no speakerbox).
 *   REG3  test: stored.
 *   REG8  command-queue pointer (DVMA): a write starts the queue there.
 *   REG9  interrupt-queue pointer: the next interrupt word's DVMA address.
 * The command processor runs to the next WAIT inside the register write:
 *   WAIT stops with REG8 on it; PAUSE is a no-op (no pipes run); JUMP loads
 *   the next word; IIQ sets the interrupt queue; every other command is
 *   skipped by its length.  A command with its I bit set posts a CMDI
 *   interrupt (channel 38, the opcode, the low 16 bits).
 * Interrupt queue: 64-word blocks; word 0 links to the next block and the
 * chip writes words 1..63 (Linux dbri_process_interrupt_buffer).  The line is
 * SBus level 5 (processor level 9, intctl source 11).
 * Not modeled: data pipes, time slots, CHI/codec, NT/TE.  Not in checkpoints
 * (a version-5 checkpoint restores with the DBRI reset). */
#include <cstdio>
#include <cstring>

#include "interpret.hh"
#include "sun4m.hh"

enum : uint32_t {
  DBRI_D_P = 1u << 15, DBRI_D_R = 1u << 0,      /* REG0 */
  DBRI_D_IR = 1u << 0,                          /* REG1 */
  DBRI_WAIT = 0x0, DBRI_PAUSE = 0x1, DBRI_JUMP = 0x2, DBRI_IIQ = 0x3,
  DBRI_INTR_CMDI = 6, DBRI_INTR_CMD = 38,
  DBRI_INT_BLK = 64,
  DBRI_MAX_CMDS = 4096,                         /* a runaway queue stops here */
};

/* words per command, by opcode (the driver's dbri_cmd_info table) */
static const uint32_t dbri_cmd_len[16] = {1, 1, 2, 2, 1, 2, 1, 3, 2, 1, 1, 1, 1, 3, 1, 1};

uint32_t sun4m_t::dbri_rd32(uint32_t dvma) {
  uint8_t b[4];
  iommu_dma("dbri", dvma, b, 4, false);
  return (static_cast<uint32_t>(b[0]) << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

void sun4m_t::dbri_wr32(uint32_t dvma, uint32_t v) {
  uint8_t b[4] = {static_cast<uint8_t>(v >> 24), static_cast<uint8_t>(v >> 16),
		  static_cast<uint8_t>(v >> 8), static_cast<uint8_t>(v)};
  iommu_dma("dbri", dvma, b, 4, true);
}

void sun4m_t::dbri_reset() {
  dbri = dbri_t();
}

/* write one word to the interrupt queue and raise the line */
void sun4m_t::dbri_post(uint32_t word) {
  if(dbri.intq_base == 0) {
    return;                  /* no IIQ yet: the chip has nowhere to report */
  }
  dbri_wr32(dbri.intq_base + 4 * dbri.intq_idx, word);
  if(++dbri.intq_idx == DBRI_INT_BLK) {
    dbri.intq_base = dbri_rd32(dbri.intq_base);   /* word 0: the next block */
    dbri.intq_idx = 1;
  }
  dbri.irq = true;
}

/* execute commands from REG8 until a WAIT */
void sun4m_t::dbri_run() {
  for(uint32_t n = 0; n < DBRI_MAX_CMDS; n++) {
    const uint32_t w = dbri_rd32(dbri.cmdp);
    const uint32_t op = w >> 28;
    if((w >> 27) & 1) {
      dbri_post((DBRI_INTR_CMD << 24) | (DBRI_INTR_CMDI << 20) | (op << 16) | (w & 0xffff));
    }
    switch(op)
      {
      case DBRI_WAIT:
	return;
      case DBRI_JUMP:
	dbri.cmdp = dbri_rd32(dbri.cmdp + 4);
	continue;
      case DBRI_IIQ:
	dbri.intq_base = dbri_rd32(dbri.cmdp + 4);
	dbri.intq_idx = 1;
	break;
      default:
	break;
      }
    dbri.cmdp += 4 * dbri_cmd_len[op];
  }
  fprintf(stderr, "sun4m: dbri: no WAIT in %u commands, stopped at 0x%08x\n",
	  static_cast<uint32_t>(DBRI_MAX_CMDS), dbri.cmdp);
}

uint32_t sun4m_t::dbri_read(uint32_t reg) {
  switch(reg)
    {
    case 0x00: return dbri.reg0;
    case 0x04: {
      const uint32_t v = dbri.reg1 | (dbri.irq ? DBRI_D_IR : 0);
      dbri.irq = false;
      return v;
    }
    case 0x08: return dbri.reg2 & ~0xfu;        /* PIO inputs: no codec */
    case 0x0c: return dbri.reg3;
    case 0x20: return dbri.cmdp;
    case 0x24: return dbri.intq_base + 4 * dbri.intq_idx;
    default: return 0;
    }
}

void sun4m_t::dbri_write(uint32_t reg, uint32_t v) {
  switch(reg)
    {
    case 0x00:
      if(v & DBRI_D_R) {
	dbri_reset();
	return;
      }
      dbri.reg0 = v & ~DBRI_D_P;
      if(v & DBRI_D_P) {
	dbri_run();
      }
      break;
    case 0x04: dbri.reg1 = v; break;
    case 0x08: dbri.reg2 = v; break;
    case 0x0c: dbri.reg3 = v; break;
    case 0x20:
      dbri.cmdp = v;
      dbri_run();
      break;
    default: break;
    }
}
