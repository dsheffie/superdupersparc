/* Sun CG14 on a VSIMM; see cg14.hh. */
#include <algorithm>
#include <cstdio>

#include "cg14.hh"

enum : uint32_t {
  CG14_MCR = 0x0000, CG14_REV = 0x0006,
  CG14_HBS = 0x0018, CG14_HBC = 0x001a, CG14_VBS = 0x0022, CG14_VBC = 0x0024,
  CG14_CURSOR = 0x1000, CG14_CLUT1 = 0x4000,
  CG14_CPL0 = 0x000, CG14_CPL1 = 0x080, CG14_CCR = 0x100, CG14_CURSX = 0x104, CG14_CURSY = 0x106,
  CG14_COLOR0 = 0x108, CG14_COLOR1 = 0x10c,
  CG14_MCR_PIXMODE_SHIFT = 4, CG14_PIXMODE_32 = 3,
  CG14_CCR_ENABLE = 0x04,
};

void cg14_t::reset() {
  regs.assign(REG_SPAN, 0);
  vram.assign(VRAM_SIZE, 0);
  regs[CG14_REV] = 0x10;                       /* revision 1, implementation 0 */
  gen++;
}

uint32_t cg14_t::reg32(uint32_t off) const {
  return (static_cast<uint32_t>(regs[off]) << 24) | (regs[off + 1] << 16) | (regs[off + 2] << 8) | regs[off + 3];
}

/* the first access to each offset, to see what the PROM and the OS use */
void cg14_t::note(const char *what, uint64_t off, uint32_t size, bool wr, uint32_t v) {
  if(seen.insert((wr ? 1ULL << 63 : 0) | (static_cast<uint64_t>(what[0]) << 40) | off).second) {
    fprintf(stderr, "cg14: %s %s%u +0x%llx = 0x%x\n", what, wr ? "write" : "read", size * 8,
	    static_cast<unsigned long long>(off), v);
  }
}

uint32_t cg14_t::read(uint64_t pa, uint32_t size) {
  uint32_t v = 0;
  if(pa >= REG_BASE and pa < REG_BASE + REG_SPAN) {
    const uint64_t off = pa - REG_BASE;
    for(uint32_t i = 0; i < size and off + i < REG_SPAN; i++) {
      v = (v << 8) | regs[off + i];
    }
    if(off >= CG14_CLUT1 + 0x400 or off < CG14_CURSOR) {
      note("reg", off, size, false, v);
    }
    return v;
  }
  const uint64_t off = pa - VRAM_BASE;
  if(off >= 0x1000000) {
    note("vram view", off, size, false, 0);
    return 0;
  }
  for(uint32_t i = 0; i < size; i++) {
    v = (v << 8) | vram[(off + i) & (VRAM_SIZE - 1)];
  }
  return v;
}

void cg14_t::write(uint64_t pa, uint32_t size, uint32_t v) {
  if(pa >= REG_BASE and pa < REG_BASE + REG_SPAN) {
    const uint64_t off = pa - REG_BASE;
    if(off >= CG14_CLUT1 + 0x400 or off < CG14_CURSOR) {
      note("reg", off, size, true, v);
    }
    if(off == CG14_REV) {
      return;                                  /* read-only */
    }
    for(uint32_t i = 0; i < size and off + i < REG_SPAN; i++) {
      regs[off + i] = static_cast<uint8_t>(v >> (8 * (size - 1 - i)));
    }
    gen++;
    return;
  }
  const uint64_t off = pa - VRAM_BASE;
  if(off >= 0x1000000) {
    note("vram view", off, size, true, v);
    return;
  }
  for(uint32_t i = 0; i < size; i++) {
    vram[(off + i) & (VRAM_SIZE - 1)] = static_cast<uint8_t>(v >> (8 * (size - 1 - i)));
  }
  gen++;
}

static uint32_t clamp_dim(int32_t v, uint32_t max) {
  return (v <= 0) ? 1 : std::min<uint32_t>(static_cast<uint32_t>(v), max);
}

uint32_t cg14_t::width() const {
  const int32_t hbs = (regs[CG14_HBS] << 8) | regs[CG14_HBS + 1];
  const int32_t hbc = (regs[CG14_HBC] << 8) | regs[CG14_HBC + 1];
  return clamp_dim(4 * (hbs - hbc), MAX_W);
}

uint32_t cg14_t::height() const {
  const int32_t vbs = (regs[CG14_VBS] << 8) | regs[CG14_VBS + 1];
  const int32_t vbc = (regs[CG14_VBC] << 8) | regs[CG14_VBC + 1];
  return clamp_dim(vbs - vbc, MAX_H);
}

static inline uint32_t xbgr_to_rgb(uint32_t c) {
  return ((c & 0xff) << 16) | (c & 0xff00) | ((c >> 16) & 0xff);
}

void cg14_t::render(uint32_t *out) const {
  uint32_t mode = (regs[CG14_MCR] >> CG14_MCR_PIXMODE_SHIFT) & 3;
  if(depth_override != 0) {
    mode = (depth_override == 32) ? CG14_PIXMODE_32 : 0;
  }
  uint32_t pal[256];
  for(uint32_t i = 0; i < 256; i++) {
    pal[i] = xbgr_to_rgb(reg32(CG14_CLUT1 + 4 * i));
  }
  const uint32_t W = width(), H = height();
  for(uint32_t y = 0; y < H; y++) {
    uint32_t *d = out + y * W;
    for(uint32_t x = 0; x < W; x++) {
      if(mode == CG14_PIXMODE_32) {
	const uint32_t a = (4 * (y * W + x)) & (VRAM_SIZE - 4);
	const uint32_t c = (static_cast<uint32_t>(vram[a]) << 24) | (vram[a + 1] << 16) | (vram[a + 2] << 8) | vram[a + 3];
	d[x] = xbgr_to_rgb(c);
      }
      else {
	d[x] = pal[vram[y * W + x]];
      }
    }
  }
  /* the 32x32 hardware cursor: plane 0 enables, plane 1 picks color1 */
  const uint8_t *cur = &regs[CG14_CURSOR];
  if(not (cur[CG14_CCR] & CG14_CCR_ENABLE)) {
    return;
  }
  const int32_t cx = static_cast<int16_t>((cur[CG14_CURSX] << 8) | cur[CG14_CURSX + 1]);
  const int32_t cy = static_cast<int16_t>((cur[CG14_CURSY] << 8) | cur[CG14_CURSY + 1]);
  const uint32_t c0 = xbgr_to_rgb(reg32(CG14_CURSOR + CG14_COLOR0));
  const uint32_t c1 = xbgr_to_rgb(reg32(CG14_CURSOR + CG14_COLOR1));
  for(int32_t r = 0; r < 32; r++) {
    const int32_t y = cy + r;
    if(y < 0 or y >= static_cast<int32_t>(H)) {
      continue;
    }
    const uint32_t p0 = reg32(CG14_CURSOR + CG14_CPL0 + 4 * r);
    const uint32_t p1 = reg32(CG14_CURSOR + CG14_CPL1 + 4 * r);
    for(int32_t i = 0; i < 32; i++) {
      const int32_t x = cx + i;
      const uint32_t bit = 0x80000000u >> i;
      if(x >= 0 and x < static_cast<int32_t>(W) and (p0 & bit)) {
	out[y * W + x] = (p1 & bit) ? c1 : c0;
      }
    }
  }
}
