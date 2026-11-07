/* Am7990 Lance Ethernet behind the sun4m ledma (qemu hw/net/lance.c +
 * pcnet.c in its 16-bit Lance mode).  Enough for a driver to initialize
 * and start the chip and to send: there is no network backend, so frames
 * on the transmit ring are completed and dropped, and nothing arrives.
 *
 * The chip's DMA goes out through the ledma: Lance address | ledma reg 3
 * (the DVMA high byte) through the IOMMU.  The init block and descriptors
 * are 16-bit words, big-endian in memory (qemu: the ledma swaps each word,
 * pcnet then reads it little-endian). */
#include <cstdio>
#include <cstring>

#include "interpret.hh"
#include "sun4m.hh"

enum : uint16_t {
  LE_ERR = 0x8000, LE_BABL = 0x4000, LE_CERR = 0x2000, LE_MISS = 0x1000, LE_MERR = 0x0800,
  LE_RINT = 0x0400, LE_TINT = 0x0200, LE_IDON = 0x0100, LE_INTR = 0x0080, LE_INEA = 0x0040,
  LE_RXON = 0x0020, LE_TXON = 0x0010, LE_TDMD = 0x0008, LE_STOP = 0x0004, LE_STRT = 0x0002,
  LE_INIT = 0x0001,
  LE_OWN = 0x8000, LE_ENP = 0x0100,
};

uint16_t sun4m_t::lance_rd16(uint32_t addr) {
  uint8_t b[2];
  iommu_dma("ledma", ledma.r[3] | (addr & 0x00fffffe), b, 2, false);
  return static_cast<uint16_t>((b[0] << 8) | b[1]);
}

void sun4m_t::lance_wr16(uint32_t addr, uint16_t v) {
  uint8_t b[2] = {static_cast<uint8_t>(v >> 8), static_cast<uint8_t>(v)};
  iommu_dma("ledma", ledma.r[3] | (addr & 0x00fffffe), b, 2, true);
}

/* qemu pcnet_update_irq: INTR = any interrupt flag, ERR = any error flag; the
 * line to the ledma is INTR & INEA */
void sun4m_t::lance_update_irq() {
  uint16_t &c0 = lance.csr[0];
  c0 &= ~(LE_ERR | LE_INTR);
  if(c0 & (LE_BABL | LE_CERR | LE_MISS | LE_MERR)) {
    c0 |= LE_ERR;
  }
  if(c0 & (LE_BABL | LE_MISS | LE_MERR | LE_RINT | LE_TINT | LE_IDON)) {
    c0 |= LE_INTR;
  }
  dma_set_irq(ledma, (c0 & LE_INTR) and (c0 & LE_INEA));
}

/* the ledma's reset line, and power on (qemu pcnet_h_reset) */
void sun4m_t::lance_reset() {
  lance = lance_t();
  lance_update_irq();
}

/* qemu pcnet_init: the init block at CSR2:CSR1 --
 *   0 MODE, 2-6 PADR, 8-14 LADRF, 16 RDRA[15:0], 18 RLEN<<13 | RDRA[23:16],
 *   20 TDRA[15:0], 22 TLEN<<13 | TDRA[23:16] */
void sun4m_t::lance_init() {
  const uint32_t ib = ((lance.csr[2] & 0xff) << 16) | (lance.csr[1] & 0xfffe);
  const uint16_t rd_lo = lance_rd16(ib + 16), rd_hi = lance_rd16(ib + 18);
  const uint16_t td_lo = lance_rd16(ib + 20), td_hi = lance_rd16(ib + 22);
  lance.rdra = ((rd_hi & 0xff) << 16) | rd_lo;
  lance.rlen = 1u << ((rd_hi >> 13) & 7);
  lance.tdra = ((td_hi & 0xff) << 16) | td_lo;
  lance.tlen = 1u << ((td_hi >> 13) & 7);
  lance.tx_idx = 0;
  lance.csr[0] &= ~LE_STOP;
  lance.csr[0] |= LE_IDON | LE_INIT;
}

/* qemu pcnet_transmit: every frame (STP .. ENP) the chip owns goes out --
 * here, nowhere -- and its descriptors are handed back with OWN clear.
 * Descriptor words: 0 LADR[15:0], 2 OWN ... STP ENP | HADR, 4 -BCNT, 6 status */
void sun4m_t::lance_transmit() {
  lance.csr[0] &= ~LE_TDMD;
  if(not (lance.csr[0] & LE_TXON)) {
    return;
  }
  bool sent = false;
  for(uint32_t n = 0; n < lance.tlen; n++) {
    const uint32_t d = lance.tdra + 8 * lance.tx_idx;
    const uint16_t t1 = lance_rd16(d + 2);
    if(not (t1 & LE_OWN)) {
      break;
    }
    lance_wr16(d + 6, 0);
    lance_wr16(d + 2, t1 & ~LE_OWN);
    lance.tx_idx = (lance.tx_idx + 1) % lance.tlen;
    if(t1 & LE_ENP) {
      sent = true;
    }
  }
  if(sent) {
    lance.csr[0] |= LE_TINT;
  }
}

/* reg 0 RDP (the CSR RAP selects), reg 1 RAP */
uint16_t sun4m_t::lance_read(uint32_t reg) {
  if(reg != 0) {
    return lance.rap;
  }
  return lance.csr[lance.rap & 3];
}

/* qemu pcnet_csr_writew for CSR0: the interrupt flags are write-one-to-clear,
 * INEA and TDMD are written, STOP/INIT/STRT act on a 0->1 edge (all three
 * at once is STOP alone); CSR1-3 are only writable while stopped */
void sun4m_t::lance_write(uint32_t reg, uint16_t v) {
  if(reg != 0) {
    lance.rap = v & 3;
    return;
  }
  if(lance.rap != 0) {
    if(lance.csr[0] & LE_STOP) {
      lance.csr[lance.rap] = v;
    }
    return;
  }
  uint16_t &c0 = lance.csr[0];
  c0 &= ~(v & (LE_BABL | LE_CERR | LE_MISS | LE_MERR | LE_RINT | LE_TINT | LE_IDON));
  c0 = (c0 & ~LE_INEA) | (v & (LE_INEA | LE_TDMD));
  uint16_t cmd = v & (LE_STOP | LE_STRT | LE_INIT);
  if(cmd == (LE_STOP | LE_STRT | LE_INIT)) {
    cmd = LE_STOP;
  }
  if((cmd & LE_STOP) and not (c0 & LE_STOP)) {
    c0 = LE_STOP;                          /* qemu pcnet_stop */
  }
  if((cmd & LE_INIT) and not (c0 & LE_INIT)) {
    lance_init();
  }
  if((cmd & LE_STRT) and not (c0 & LE_STRT)) {
    c0 &= ~LE_STOP;                        /* qemu pcnet_start */
    c0 |= LE_STRT | LE_TXON | LE_RXON;
  }
  if(c0 & LE_TDMD) {
    lance_transmit();
  }
  lance_update_irq();
}
