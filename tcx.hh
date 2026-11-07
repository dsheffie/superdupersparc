#ifndef __TCX_HH__
#define __TCX_HH__

#include <cstdint>
#include <string>
#include <vector>

#include "fb.hh"

/* Sun TCX framebuffer in SBus slot 2 (0xe20000000 on the SS-20), as qemu
 * hw/display/tcx.c models it in its 8-bit mode: 1024x768 pseudocolor, the
 * Brooktree-style DAC, the THC hardware cursor, and the stipple/blit
 * engines.  The FCode PROM at offset 0 is qemu's open-source QEMU,tcx.bin,
 * which the real Sun OBP runs to create the SUNW,tcx node and its console.
 *
 * Offsets from the slot base (qemu sun4m.c tcx_init):
 *   0x0000000 FCode ROM       0x0200000 DAC         0x0240000 DHC (dummy)
 *   0x0280000 ALT (dummy)     0x0300000 THC         0x0301000 THC24 (dummy)
 *   0x0700000 TEC (dummy)     0x0800000 8-bit plane 0x2000000 24-bit plane
 *   0x4000000 stipple         0x6000000 blit        0xa000000 control plane
 *   0xc000000 raw stipple     0xe000000 raw blit */
struct tcx_t : framebuffer_t {
  static const uint32_t W = 1024, H = 768;
  static const uint32_t VRAM = 0x100000;       /* qemu vram_size: 1 MB */
  static const uint64_t BASE = 0xe20000000ULL, SPAN = 0x10000000ULL;

  std::vector<uint8_t> rom;                    /* the FCode (not checkpointed: reloaded) */
  std::vector<uint8_t> vram;                   /* 8-bit plane */
  std::vector<uint32_t> vram24, cplane;        /* 24-bit and control planes (stored, not shown) */
  uint8_t r[260] = {0}, g[260] = {0}, b[260] = {0};   /* 0-255 pixels, 256-259 cursor */
  uint8_t dac_index = 0, dac_state = 0;
  uint32_t tmpblit = 0, thcmisc = 0;
  uint32_t cursmask[32] = {0}, cursbits[32] = {0};
  uint16_t cursx = 0xf000, cursy = 0xf000;

  bool load_rom(const std::string &fn);
  void reset();
  uint32_t read(uint64_t off, uint32_t size);
  void write(uint64_t off, uint32_t size, uint32_t v);
  uint32_t width() const override { return W; }
  uint32_t height() const override { return H; }
  void render(uint32_t *out) const override;
private:
  void stip_write(uint64_t off, uint32_t v, bool raw);
  void blit_write(uint64_t off, uint32_t v, bool raw);
  void dac_write(uint64_t off, uint32_t v);
  uint32_t dac_read();
  void thc_write(uint64_t off, uint32_t v);
};

#endif
