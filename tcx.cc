/* Sun TCX, 8-bit mode (qemu hw/display/tcx.c); see tcx.hh for the map. */
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>

#include "tcx.hh"

enum : uint64_t {
  TCX_ROM = 0x0000000, TCX_DAC = 0x0200000, TCX_THC = 0x0300000, TCX_DFB8 = 0x0800000,
  TCX_DFB24 = 0x2000000, TCX_STIP = 0x4000000, TCX_BLIT = 0x6000000, TCX_CPLANE = 0xa000000,
  TCX_RSTIP = 0xc000000, TCX_RBLIT = 0xe000000,
  TCX_ENGINE_SPAN = 0x800000,
  TCX_THC_MISC = 0x818, TCX_THC_CURSXY = 0x8fc, TCX_THC_CURSMASK = 0x900, TCX_THC_CURSBITS = 0x980,
};

bool tcx_t::load_rom(const std::string &fn) {
  std::ifstream f(fn, std::ios::binary);
  if(not f) {
    return false;
  }
  rom.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
  rom.resize(0x10000, 0);                      /* qemu FCODE_MAX_ROM_SIZE */
  return true;
}

/* qemu tcx_reset: black palette but entry 255 and cursor colours 256/258
 * white, the screen cleared, the cursor off screen */
void tcx_t::reset() {
  vram.assign(VRAM, 0);
  vram24.assign(VRAM, 0);
  cplane.assign(VRAM, 0);
  memset(r, 0, sizeof(r));
  memset(g, 0, sizeof(g));
  memset(b, 0, sizeof(b));
  r[255] = g[255] = b[255] = 255;
  r[256] = g[256] = b[256] = 255;
  r[258] = g[258] = b[258] = 255;
  dac_index = 0;
  dac_state = 0;
  cursx = 0xf000;
  cursy = 0xf000;
  gen++;
}

/* qemu tcx_dac_readl: R, G, B of the current index, then the index advances */
uint32_t tcx_t::dac_read() {
  uint32_t v = 0;
  switch(dac_state)
    {
    case 0:
      v = r[dac_index] << 24;
      dac_state++;
      break;
    case 1:
      v = g[dac_index] << 24;
      dac_state++;
      break;
    case 2:
      v = b[dac_index] << 24;
      dac_index = (dac_index + 1) & 0xff;
      dac_state = 0;
      break;
    default:
      dac_state = 0;
      break;
    }
  return v;
}

/* qemu tcx_dac_writel: 0 the index, 4 the pixel colours, 12 the cursor
 * colours (index & 3 + 256); one byte per write, in the top 8 bits */
void tcx_t::dac_write(uint64_t off, uint32_t v) {
  if(off == 0) {
    dac_index = v >> 24;
    dac_state = 0;
    return;
  }
  if(off != 4 and off != 12) {
    return;                                    /* control registers */
  }
  const uint32_t i = (off & 8) ? (dac_index & 3) + 256 : dac_index;
  switch(dac_state)
    {
    case 0:
      r[i] = v >> 24;
      dac_state++;
      break;
    case 1:
      g[i] = v >> 24;
      dac_state++;
      break;
    case 2:
      b[i] = v >> 24;
      dac_index = (dac_index + 1) & 0xff;
      dac_state = 0;
      break;
    default:
      dac_state = 0;
      break;
    }
  gen++;
}

/* qemu tcx_thc_writel: the cursor position (x << 16 | y), its 32x32 mask
 * and bits, and THC_MISC */
void tcx_t::thc_write(uint64_t off, uint32_t v) {
  if(off == TCX_THC_CURSXY) {
    cursx = v >> 16;
    cursy = v & 0xffff;
  }
  else if(off >= TCX_THC_CURSMASK and off < TCX_THC_CURSMASK + 128) {
    cursmask[(off - TCX_THC_CURSMASK) >> 2] = v;
  }
  else if(off >= TCX_THC_CURSBITS and off < TCX_THC_CURSBITS + 128) {
    cursbits[(off - TCX_THC_CURSBITS) >> 2] = v;
  }
  else if(off == TCX_THC_MISC) {
    thcmisc = v;
    return;
  }
  else {
    return;
  }
  gen++;
}

/* qemu tcx_stip_writel / tcx_rstip_writel: the even word is the colour, the
 * odd word a 32-pixel mask for the pixels at (offset >> 3) */
void tcx_t::stip_write(uint64_t off, uint32_t v, bool raw) {
  if(not (off & 4)) {
    tmpblit = v;
    return;
  }
  const uint32_t a = (off >> 3) & 0xfffff;
  const uint32_t col = tmpblit;
  for(uint32_t i = 0; i < 32; i++) {
    if((v & 0x80000000u) and a + i < VRAM) {
      vram[a + i] = static_cast<uint8_t>(tmpblit);
      vram24[a + i] = col;
      if(raw) {
	cplane[a + i] = col;
      }
    }
    v <<= 1;
  }
  gen++;
}

/* qemu tcx_blit_writel / tcx_rblit_writel: the even word is a fill colour,
 * the odd word (len - 1) << 24 | source; source 0xffffff fills, else copies
 * len pixels to (offset >> 3) */
void tcx_t::blit_write(uint64_t off, uint32_t v, bool raw) {
  if(not (off & 4)) {
    tmpblit = v;
    return;
  }
  const uint32_t a = (off >> 3) & 0xfffff;
  const uint32_t src = v & 0xffffff;
  const uint32_t len = ((v >> 24) & 0x1f) + 1;
  if(a + len > VRAM) {
    return;
  }
  if(src == 0xffffff) {
    memset(&vram[a], static_cast<uint8_t>(tmpblit), len);
    for(uint32_t i = 0; i < len; i++) {
      vram24[a + i] = tmpblit & 0xffffff;
      if(raw) {
	cplane[a + i] = tmpblit & 0xffffff;
      }
    }
  }
  else if(src + len <= VRAM) {
    memmove(&vram[a], &vram[src], len);
    memmove(&vram24[a], &vram24[src], len * 4);
    if(raw) {
      memmove(&cplane[a], &cplane[src], len * 4);
    }
  }
  gen++;
}

uint32_t tcx_t::read(uint64_t off, uint32_t size) {
  if(off < rom.size()) {
    uint32_t v = 0;
    for(uint32_t i = 0; i < size and off + i < rom.size(); i++) {
      v = (v << 8) | rom[off + i];
    }
    return v;
  }
  if(off >= TCX_DFB8 and off < TCX_DFB8 + VRAM) {
    uint32_t v = 0;
    for(uint32_t i = 0; i < size; i++) {
      v = (v << 8) | vram[(off - TCX_DFB8 + i) & (VRAM - 1)];
    }
    return v;
  }
  if(off >= TCX_DFB24 and off < TCX_DFB24 + 4 * VRAM) {
    return vram24[(off - TCX_DFB24) >> 2];
  }
  if(off >= TCX_CPLANE and off < TCX_CPLANE + 4 * VRAM) {
    return cplane[(off - TCX_CPLANE) >> 2];
  }
  if(off >= TCX_DAC and off < TCX_DAC + 16) {
    return dac_read();
  }
  if(off == TCX_THC + TCX_THC_MISC) {
    return thcmisc | 0x02000000;               /* qemu: the vertical-retrace bit */
  }
  return 0;                                    /* engines, TEC, DHC, ALT, THC: read 0 */
}

void tcx_t::write(uint64_t off, uint32_t size, uint32_t v) {
  if(off >= TCX_DFB8 and off < TCX_DFB8 + VRAM) {
    for(uint32_t i = 0; i < size; i++) {
      vram[(off - TCX_DFB8 + i) & (VRAM - 1)] = static_cast<uint8_t>(v >> (8 * (size - 1 - i)));
    }
    gen++;
  }
  else if(off >= TCX_DFB24 and off < TCX_DFB24 + 4 * VRAM) {
    vram24[(off - TCX_DFB24) >> 2] = v;
  }
  else if(off >= TCX_CPLANE and off < TCX_CPLANE + 4 * VRAM) {
    cplane[(off - TCX_CPLANE) >> 2] = v;
  }
  else if(off >= TCX_DAC and off < TCX_DAC + 16) {
    dac_write(off - TCX_DAC, v);
  }
  else if(off >= TCX_THC and off < TCX_THC + 0x1000) {
    thc_write(off - TCX_THC, v);
  }
  else if(off >= TCX_STIP and off < TCX_STIP + TCX_ENGINE_SPAN) {
    stip_write(off - TCX_STIP, v, false);
  }
  else if(off >= TCX_RSTIP and off < TCX_RSTIP + TCX_ENGINE_SPAN) {
    stip_write(off - TCX_RSTIP, v, true);
  }
  else if(off >= TCX_BLIT and off < TCX_BLIT + TCX_ENGINE_SPAN) {
    blit_write(off - TCX_BLIT, v, false);
  }
  else if(off >= TCX_RBLIT and off < TCX_RBLIT + TCX_ENGINE_SPAN) {
    blit_write(off - TCX_RBLIT, v, true);
  }
  /* the ROM, TEC, DHC, ALT and THC24 ignore writes */
}

/* qemu tcx_draw_line32 + tcx_draw_cursor32: pseudocolour through the
 * palette; where the cursor mask is set, colour 259 (bit set) or 258 */
void tcx_t::render(uint32_t *out) const {
  uint32_t pal[260];
  for(uint32_t i = 0; i < 260; i++) {
    pal[i] = (static_cast<uint32_t>(r[i]) << 16) | (g[i] << 8) | b[i];
  }
  for(uint32_t y = 0; y < H; y++) {
    const uint8_t *s = &vram[y * 1024];
    uint32_t *d = out + y * W;
    for(uint32_t x = 0; x < W; x++) {
      d[x] = pal[s[x]];
    }
    if(y >= cursy and y < static_cast<uint32_t>(cursy) + 32 and cursx < W) {
      const uint32_t m = cursmask[y - cursy], c = cursbits[y - cursy];
      for(uint32_t i = 0; i < 32 and cursx + i < W; i++) {
	const uint32_t bit = 0x80000000u >> i;
	if(m & bit) {
	  d[cursx + i] = (c & bit) ? pal[259] : pal[258];
	}
      }
    }
  }
}
