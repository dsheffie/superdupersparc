#ifndef __CG14_HH__
#define __CG14_HH__

#include <cstdint>
#include <set>
#include <vector>

#include "fb.hh"

/* Sun CG14 (the SS-10/20 SX graphics on a VSIMM), in VSIMM slot 3: the
 * registers at 0x9c000000 and an 8 MB VRAM in the 64 MB window at
 * 0xfc000000 (qemu sun4m.c ss20 vsimm[0]).  The Sun OBP has the driver built
 * in; its POST finds the VSIMM by writing/reading back the master control
 * register and sizes the VRAM from where it aliases (8 MB: every 8 MB).
 *
 * Register window, by page (Linux drivers/video/fbdev/cg14.c):
 *   0x0000 control (MCR, PPR, MSR, REV, timing, VBC)   0x1000 cursor
 *   0x2000 DAC   0x3000 XLUT   0x4000 CLUT1   0x5000 CLUT2   0x6000 CLUT3
 * CLUT entries are 0xAABBGGRR.  Pixels: MCR[5:4] = 0 8-bit through CLUT1,
 * 3 32-bit XBGR (NetBSD cg14_set_depth).  NeXTSTEP's WindowServer draws
 * 32-bit XBGR while leaving MCR in 8-bit mode (with PPR = 0x80); no
 * documented register says so, hence depth_override (main: --cg14-depth). */
struct cg14_t : framebuffer_t {
  static const uint64_t REG_BASE = 0x9c000000ULL, REG_SPAN = 0x7000;
  static const uint64_t VRAM_BASE = 0xfc000000ULL, VRAM_SPAN = 0x4000000;
  static const uint32_t VRAM_SIZE = 0x800000;
  static const uint32_t MAX_W = 1280, MAX_H = 1024;

  std::vector<uint8_t> regs;                   /* the register window, REG_SPAN bytes */
  std::vector<uint8_t> vram;
  std::set<uint64_t> seen;                     /* offsets reported once (not checkpointed) */
  uint32_t depth_override = 0;                 /* 8 or 32 forces the display depth; 0 = MCR */

  void reset();
  uint32_t read(uint64_t pa, uint32_t size);
  void write(uint64_t pa, uint32_t size, uint32_t v);
  /* the mode the video timing describes: active pixels = (HBS - HBC) * 4,
   * lines = VBS - VBC (OBP: 1024x768 when the monitor sense reads 0) */
  uint32_t width() const override;
  uint32_t height() const override;
  void render(uint32_t *out) const override;
private:
  uint32_t reg32(uint32_t off) const;
  void note(const char *what, uint64_t off, uint32_t size, bool wr, uint32_t v);
};

#endif
