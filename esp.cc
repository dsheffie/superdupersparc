/* The sun4m ESP: qemu 8.2 hw/scsi/esp.c, function for function, for the host it
 * has on sparc32 -- the espdma supplies dma_memory_read/dma_memory_write, so
 * every DMA path moves bytes through the espdma (and the IOMMU) and the PDMA
 * callbacks other ESP hosts use do not exist.  qemu's SCSI layer callbacks
 * (scsi_req_enqueue / scsi_req_continue -> esp_transfer_data /
 * esp_command_complete) run synchronously: scsi.hh's targets have the data at
 * once, as qemu's emulated commands do. */
#include <cstdio>
#include <cstring>
#include <algorithm>

#include "sun4m.hh"
#include "interpret.hh"

enum : uint8_t {
  ESP_TCLO = 0x0, ESP_TCMID = 0x1, ESP_FIFO = 0x2, ESP_CMD = 0x3, ESP_RSTAT = 0x4, ESP_WBUSID = 0x4,
  ESP_RINTR = 0x5, ESP_RSEQ = 0x6, ESP_RFLAGS = 0x7, ESP_WSYNO = 0x7, ESP_CFG1 = 0x8, ESP_WCCF = 0x9,
  ESP_WTEST = 0xa, ESP_CFG2 = 0xb, ESP_CFG3 = 0xc, ESP_RES3 = 0xd, ESP_TCHI = 0xe, ESP_RES4 = 0xf,
  CMD_DMA = 0x80, CMD_CMD = 0x7f,
  CMD_NOP = 0x00, CMD_FLUSH = 0x01, CMD_RESET = 0x02, CMD_BUSRESET = 0x03, CMD_TI = 0x10,
  CMD_ICCS = 0x11, CMD_MSGACC = 0x12, CMD_PAD = 0x18, CMD_SATN = 0x1a, CMD_RSTATN = 0x1b,
  CMD_SEL = 0x41, CMD_SELATN = 0x42, CMD_SELATNS = 0x43, CMD_ENSEL = 0x44, CMD_DISSEL = 0x45,
  STAT_DO = 0x00, STAT_DI = 0x01, STAT_CD = 0x02, STAT_ST = 0x03, STAT_MO = 0x06, STAT_MI = 0x07,
  STAT_PIO_MASK = 0x06, STAT_TC = 0x10, STAT_INT = 0x80,
  BUSID_DID = 0x07, INTR_FC = 0x08, INTR_BS = 0x10, INTR_DC = 0x20, INTR_RST = 0x80,
  SEQ_0 = 0x0, SEQ_MO = 0x1, SEQ_CD = 0x4, CFG1_RESREPT = 0x40, TCHI_FAS100A = 0x4
};
static const uint32_t ESP_FIFO_SZ = 16, ESP_CMDFIFO_SZ = 32;

/* a DMA command deferred until the espdma enables the ESP's DMA (qemu dma_cb) */
enum : uint8_t { DMA_CB_NONE = 0, DMA_CB_SATN, DMA_CB_SEL, DMA_CB_SATNS, DMA_CB_TI };

/* ---- qemu Fifo8 on a vector ---- */
static void fifo_push(std::vector<uint8_t> &f, uint32_t cap, uint8_t v) {
  if(f.size() < cap) {       /* esp_fifo_push: an overrun is dropped */
    f.push_back(v);
  }
}
static uint8_t fifo_pop(std::vector<uint8_t> &f) {
  if(f.empty()) {
    return 0;
  }
  uint8_t v = f.front();
  f.erase(f.begin());
  return v;
}
static uint32_t fifo_pop_buf(std::vector<uint8_t> &f, uint8_t *dst, uint32_t n) {
  n = std::min<uint32_t>(n, static_cast<uint32_t>(f.size()));
  if(dst != nullptr) {
    std::copy(f.begin(), f.begin() + n, dst);
  }
  f.erase(f.begin(), f.begin() + n);
  return n;
}

void sun4m_t::esp_raise_irq() {
  if(dma_busy != nullptr and dma_busy(dma_busy_ctx)) {
    esp.irq_deferred = true;   /* raised by dma_drained (sun4m.hh) */
    return;
  }
  if(not (esp.rregs[ESP_RSTAT] & STAT_INT)) {
    esp.rregs[ESP_RSTAT] |= STAT_INT;
    esp.irq = true;
    dma_set_irq(espdma, true);
  }
}

void sun4m_t::dma_drained() {
  if(esp.irq_deferred) {
    esp.irq_deferred = false;
    esp_raise_irq();
  }
}

void sun4m_t::esp_lower_irq() {
  if(esp.rregs[ESP_RSTAT] & STAT_INT) {
    esp.rregs[ESP_RSTAT] &= ~STAT_INT;
    esp.irq = false;
    dma_set_irq(espdma, false);
  }
}

void sun4m_t::esp_dma_enable(bool level) {
  esp.dma_enabled = level;
  if(level and esp.dma_cb != DMA_CB_NONE) {
    const uint8_t cb = esp.dma_cb;
    esp.dma_cb = DMA_CB_NONE;
    switch(cb)
      {
      case DMA_CB_SATN: esp_handle_satn(); break;
      case DMA_CB_SEL: esp_handle_s_without_atn(); break;
      case DMA_CB_SATNS: esp_handle_satn_stop(); break;
      case DMA_CB_TI: esp_handle_ti(); break;
      default: break;
      }
  }
}

/* len bytes at DVMA address dvma through the IOMMU (qemu sun4m_iommu.c: the
 * page table at BASE << 4, one entry per 4K of the range CTRL selects) */
void sun4m_t::iommu_dma(const char *who, uint32_t dvma, uint8_t *buf, uint32_t len, bool to_mem) {
  const uint32_t range = 0x01000000u << ((iommu[0] >> 2) & 7);   /* IOMMU_CTRL.RNGE */
  uint32_t done = 0;
  while(done < len) {
    const uint32_t off = dvma & 0xfff;
    const uint32_t n = std::min(len - done, 0x1000u - off);
    const uint64_t pte_pa = (static_cast<uint64_t>(iommu[1]) << 4) + (((dvma & (range - 1)) >> 12) << 2);
    uint32_t pte = 0;
    if(io_s != nullptr and pte_pa + 4 <= io_s->ram_size) {
      if(dma_snoop != nullptr) {
	dma_snoop(dma_snoop_ctx, pte_pa, 4);
      }
      const uint8_t *p = io_s->mem.mem + pte_pa;
      pte = (static_cast<uint32_t>(p[0]) << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
    }
    const uint64_t pa = (static_cast<uint64_t>(pte & 0xffffff00u) << 4) + off;
    const bool ok = (pte & 0x2) and (not to_mem or (pte & 0x4)) and io_s != nullptr and
		    pa + n <= io_s->ram_size;
    if(not ok) {
      fprintf(stderr, "sun4m: %s: bad DVMA 0x%08x (pte 0x%08x) for a %s\n", who, dvma, pte,
	      to_mem ? "write" : "read");
      if(not to_mem) {
	memset(buf + done, 0, n);
      }
    }
    else if(to_mem) {
      if(dma_snoop != nullptr) {
	dma_snoop(dma_snoop_ctx, pa, n);
      }
      memcpy(io_s->mem.mem + pa, buf + done, n);
      if(dma_snoop != nullptr) {
	dma_snoop(dma_snoop_ctx, pa, n);   /* drop a copy the CPU fetched meanwhile */
      }
      if(dma_hook != nullptr) {
	dma_hook(dma_hook_ctx, pa, buf + done, n);
      }
      else if(dma_mirror != nullptr) {
	memcpy(dma_mirror->mem.mem + pa, buf + done, n);
      }
    }
    else {
      if(dma_snoop != nullptr) {
	dma_snoop(dma_snoop_ctx, pa, n);
      }
      memcpy(buf + done, io_s->mem.mem + pa, n);
    }
    dvma += n;
    done += n;
  }
}

/* qemu espdma_memory_read/write: len bytes at the espdma address, which then
 * advances */
void sun4m_t::esp_dma_mem(uint8_t *buf, uint32_t len, bool to_mem) {
  iommu_dma("espdma", espdma.r[1], buf, len, to_mem);
  espdma.r[1] += len;
}

uint32_t sun4m_t::esp_get_tc() const {
  return esp.rregs[ESP_TCLO] | (esp.rregs[ESP_TCMID] << 8) | (esp.rregs[ESP_TCHI] << 16);
}

void sun4m_t::esp_set_tc(uint32_t v) {
  esp.rregs[ESP_TCLO] = static_cast<uint8_t>(v);
  esp.rregs[ESP_TCMID] = static_cast<uint8_t>(v >> 8);
  esp.rregs[ESP_TCHI] = static_cast<uint8_t>(v >> 16);
}

int sun4m_t::esp_select() {
  const uint32_t target = esp.wregs[ESP_WBUSID] & BUSID_DID;
  esp.ti_size = 0;
  esp.fifo.clear();
  if(scsi[target] == nullptr) {
    /* no such drive: a selection timeout */
    esp.cur_tgt = -1;
    esp.rregs[ESP_RSTAT] = 0;
    esp.rregs[ESP_RINTR] = INTR_DC;
    esp.rregs[ESP_RSEQ] = SEQ_0;
    esp_raise_irq();
    return -1;
  }
  esp.cur_tgt = static_cast<int32_t>(target);
  esp.identified = false;
  /* no interrupt yet: do_command_phase raises it for data out, the deferred
   * interrupt in esp_transfer_data for data in */
  esp.rregs[ESP_RINTR] |= INTR_FC;
  esp.rregs[ESP_RSEQ] = SEQ_CD;
  return 0;
}

int32_t sun4m_t::esp_get_cmd(uint32_t maxlen) {
  uint8_t buf[ESP_CMDFIFO_SZ];
  uint32_t dmalen;
  if(esp.req_active) {
    esp_req_cancel();        /* a new command before the old one finished */
  }
  if(esp.dma) {
    dmalen = std::min(esp_get_tc(), maxlen);
    if(dmalen == 0) {
      return 0;
    }
    esp_dma_mem(buf, dmalen, false);
    dmalen = std::min<uint32_t>(ESP_CMDFIFO_SZ - static_cast<uint32_t>(esp.cmdfifo.size()), dmalen);
    esp.cmdfifo.insert(esp.cmdfifo.end(), buf, buf + dmalen);
  }
  else {
    dmalen = std::min<uint32_t>(static_cast<uint32_t>(esp.fifo.size()), maxlen);
    if(dmalen == 0) {
      return 0;
    }
    uint32_t n = fifo_pop_buf(esp.fifo, buf, dmalen);
    n = std::min<uint32_t>(ESP_CMDFIFO_SZ - static_cast<uint32_t>(esp.cmdfifo.size()), n);
    esp.cmdfifo.insert(esp.cmdfifo.end(), buf, buf + n);
  }
  if(esp_select() < 0) {
    esp.cmdfifo.clear();
    return -1;
  }
  return static_cast<int32_t>(dmalen);
}

void sun4m_t::esp_do_command_phase() {
  const uint32_t cmdlen = static_cast<uint32_t>(esp.cmdfifo.size());
  if(cmdlen == 0 or esp.cur_tgt < 0) {
    return;
  }
  uint8_t buf[ESP_CMDFIFO_SZ] = {0};
  fifo_pop_buf(esp.cmdfifo, buf, cmdlen);
  esp.req_active = true;
  esp.req_sent = false;
  esp.async_len = 0;
  /* SCSI-2: the LUN is the IDENTIFY message's; a selection without one (OBP's
   * probe) addresses it in the CDB's byte 1, bits 7:5, the SCSI-1 way.  (qemu
   * ignores the CDB field, so its targets answer every LUN as LUN 0.) */
  const uint32_t lun = esp.identified ? esp.lun : static_cast<uint32_t>(buf[1] >> 5);
  const int32_t datalen = scsi[esp.cur_tgt]->send(lun, buf, cmdlen, esp.req);
  if(datalen == 0) {
    esp_command_complete();  /* qemu: completed inside scsi_req_enqueue */
  }
  esp.ti_size = datalen;
  esp.cmdfifo.clear();
  if(datalen != 0) {
    esp.rregs[ESP_RSTAT] = STAT_TC;
    esp.rregs[ESP_RSEQ] = SEQ_CD;
    esp.ti_cmd = 0;
    esp_set_tc(0);
    if(datalen > 0) {
      /* data in: the command completion interrupt waits for the data */
      esp.data_in_ready = false;
      esp.rregs[ESP_RSTAT] |= STAT_DI;
    }
    else {
      esp.rregs[ESP_RSTAT] |= STAT_DO;
      esp.rregs[ESP_RINTR] |= INTR_BS | INTR_FC;
      esp_raise_irq();
    }
    esp_req_continue();
  }
}

void sun4m_t::esp_do_message_phase() {
  if(esp.cmdfifo_cdb_offset) {
    const uint8_t message = fifo_pop(esp.cmdfifo);
    esp.lun = message & 7;   /* IDENTIFY */
    esp.identified = true;
    esp.cmdfifo_cdb_offset--;
  }
  /* extended messages are ignored */
  if(esp.cmdfifo_cdb_offset) {
    const uint32_t len = std::min<uint32_t>(esp.cmdfifo_cdb_offset, static_cast<uint32_t>(esp.cmdfifo.size()));
    fifo_pop_buf(esp.cmdfifo, nullptr, len);
    esp.cmdfifo_cdb_offset = 0;
  }
}

void sun4m_t::esp_do_cmd() {
  esp_do_message_phase();
  esp_do_command_phase();
}

void sun4m_t::esp_handle_satn() {
  if(esp.dma and not esp.dma_enabled) {
    esp.dma_cb = DMA_CB_SATN;
    return;
  }
  const int32_t cmdlen = esp_get_cmd(ESP_CMDFIFO_SZ);
  if(cmdlen > 0) {
    esp.cmdfifo_cdb_offset = 1;
    esp.do_cmd = false;
    esp_do_cmd();
  }
  else if(cmdlen == 0) {
    esp.do_cmd = true;       /* the target is there, no command yet: command phase */
    esp.rregs[ESP_RSEQ] = SEQ_CD;
    esp.rregs[ESP_RSTAT] = STAT_CD;
  }
}

void sun4m_t::esp_handle_s_without_atn() {
  if(esp.dma and not esp.dma_enabled) {
    esp.dma_cb = DMA_CB_SEL;
    return;
  }
  const int32_t cmdlen = esp_get_cmd(ESP_CMDFIFO_SZ);
  if(cmdlen > 0) {
    esp.cmdfifo_cdb_offset = 0;
    esp.do_cmd = false;
    esp_do_cmd();
  }
  else if(cmdlen == 0) {
    esp.do_cmd = true;
    esp.rregs[ESP_RSEQ] = SEQ_CD;
    esp.rregs[ESP_RSTAT] = STAT_CD;
  }
}

void sun4m_t::esp_handle_satn_stop() {
  if(esp.dma and not esp.dma_enabled) {
    esp.dma_cb = DMA_CB_SATNS;
    return;
  }
  const int32_t cmdlen = esp_get_cmd(1);
  if(cmdlen > 0) {
    esp.do_cmd = true;
    esp.cmdfifo_cdb_offset = 1;
    esp.rregs[ESP_RSTAT] = STAT_MO;
    esp.rregs[ESP_RINTR] |= INTR_BS | INTR_FC;
    esp.rregs[ESP_RSEQ] = SEQ_MO;
    esp_raise_irq();
  }
  else if(cmdlen == 0) {
    esp.do_cmd = true;       /* the target is there: message out phase */
    esp.rregs[ESP_RSEQ] = SEQ_MO;
    esp.rregs[ESP_RSTAT] = STAT_MO;
  }
}

/* status and message in (COMMAND COMPLETE) */
void sun4m_t::esp_write_response() {
  uint8_t buf[2] = {esp.status, 0};
  if(esp.dma) {
    esp_dma_mem(buf, 2, true);
    esp.rregs[ESP_RSTAT] = STAT_TC | STAT_ST;
    esp.rregs[ESP_RINTR] |= INTR_BS | INTR_FC;
    esp.rregs[ESP_RSEQ] = SEQ_CD;
  }
  else {
    esp.fifo.assign(buf, buf + 2);
    esp.rregs[ESP_RFLAGS] = 2;
  }
  esp_raise_irq();
}

void sun4m_t::esp_dma_done() {
  esp.rregs[ESP_RSTAT] |= STAT_TC;
  esp.rregs[ESP_RINTR] |= INTR_BS;
  esp.rregs[ESP_RFLAGS] = 0;
  esp_set_tc(0);
  esp_raise_irq();
}

void sun4m_t::esp_do_dma() {
  const bool to_device = ((esp.rregs[ESP_RSTAT] & 7) == STAT_DO);
  uint32_t len = esp_get_tc();
  if(esp.do_cmd) {
    /* handle_ti in the message out / command phase */
    uint8_t buf[ESP_CMDFIFO_SZ];
    len = std::min<uint32_t>(len, ESP_CMDFIFO_SZ - static_cast<uint32_t>(esp.cmdfifo.size()));
    esp_dma_mem(buf, len, false);
    esp.cmdfifo.insert(esp.cmdfifo.end(), buf, buf + len);
    esp.ti_size = 0;
    if((esp.rregs[ESP_RSTAT] & 7) == STAT_CD) {
      if(esp.cmdfifo_cdb_offset == esp.cmdfifo.size()) {
	return;              /* no command received */
      }
      esp.do_cmd = false;
      esp_do_cmd();
    }
    else {
      /* extra message out bytes: then the command phase */
      esp.cmdfifo_cdb_offset = static_cast<uint32_t>(esp.cmdfifo.size());
      esp.rregs[ESP_RSTAT] = STAT_TC | STAT_CD;
      esp.rregs[ESP_RSEQ] = SEQ_CD;
      esp.rregs[ESP_RINTR] |= INTR_BS;
      esp_raise_irq();
    }
    return;
  }
  if(not esp.req_active) {
    return;
  }
  if(esp.async_len == 0) {
    return;                  /* defer until data is available */
  }
  len = std::min(len, esp.async_len);
  esp_dma_mem(esp.req.buf.data() + esp.async_off, len, not to_device);
  esp_set_tc(esp_get_tc() - len);
  esp.async_off += len;
  esp.async_len -= len;
  if(to_device) {
    esp.ti_size += static_cast<int32_t>(len);
  }
  else {
    esp.ti_size -= static_cast<int32_t>(len);
  }
  if(esp.async_len == 0) {
    esp_req_continue();
    /* more to read from the device: complete the DMA now; otherwise the
     * completion was the SCSI layer's */
    if(to_device or esp_get_tc() != 0 or esp.ti_size == 0) {
      return;
    }
  }
  /* a partially filled SCSI buffer: complete now */
  esp_dma_done();
}

void sun4m_t::esp_do_nodma() {
  const bool to_device = ((esp.rregs[ESP_RSTAT] & 7) == STAT_DO);
  if(esp.do_cmd) {
    esp.ti_size = 0;
    if((esp.rregs[ESP_RSTAT] & 7) == STAT_CD) {
      if(esp.cmdfifo_cdb_offset == esp.cmdfifo.size()) {
	return;
      }
      esp.do_cmd = false;
      esp_do_cmd();
    }
    else {
      esp.cmdfifo_cdb_offset = static_cast<uint32_t>(esp.cmdfifo.size());
      esp.rregs[ESP_RSTAT] = STAT_TC | STAT_CD;
      esp.rregs[ESP_RSEQ] = SEQ_CD;
      esp.rregs[ESP_RINTR] |= INTR_BS;
      esp_raise_irq();
    }
    return;
  }
  if(not esp.req_active) {
    return;
  }
  if(esp.async_len == 0) {
    return;
  }
  if(to_device) {
    uint32_t len = std::min(esp.async_len, ESP_FIFO_SZ);
    len = std::min<uint32_t>(len, static_cast<uint32_t>(esp.fifo.size()));
    fifo_pop_buf(esp.fifo, esp.req.buf.data() + esp.async_off, len);
    esp.async_off += len;
    esp.async_len -= len;
    esp.ti_size += static_cast<int32_t>(len);
  }
  else if(esp.fifo.empty()) {
    esp.fifo.push_back(esp.req.buf[esp.async_off]);
    esp.async_off++;
    esp.async_len--;
    esp.ti_size--;
  }
  if(esp.async_len == 0) {
    esp_req_continue();
    return;
  }
  esp.rregs[ESP_RINTR] |= INTR_BS;
  esp_raise_irq();
}

/* qemu esp_request_cancelled */
void sun4m_t::esp_req_cancel() {
  esp.req_active = false;
  esp.cur_tgt = -1;
  esp.async_len = 0;
}

/* qemu scsi_req_continue on scsi.hh's target: hand the ESP the buffer (data
 * in: what the target returned; data out: room for what it receives), then,
 * once it has been moved, complete */
void sun4m_t::esp_req_continue() {
  if(not esp.req_active) {
    return;
  }
  if(not esp.req_sent and not esp.req.buf.empty()) {
    esp.req_sent = true;
    esp.async_off = 0;
    esp_transfer_data(static_cast<uint32_t>(esp.req.buf.size()));
    return;
  }
  if(esp.cur_tgt >= 0 and scsi[esp.cur_tgt] != nullptr and esp.ti_size <= 0 and
     (esp.rregs[ESP_RSTAT] & 7) == STAT_DO) {
    scsi[esp.cur_tgt]->finish_out(esp.req);
  }
  esp_command_complete();
}

void sun4m_t::esp_command_complete() {
  const bool to_device = ((esp.rregs[ESP_RSTAT] & 7) == STAT_DO);
  /* a non-DMA transfer from the target leaves its last byte in the FIFO */
  if(esp.dma or to_device) {
    esp.ti_size = 0;
  }
  esp.async_len = 0;
  esp.status = esp.req.status;
  /* the transfer is finished: the status phase */
  if(esp.ti_size == 0) {
    esp.rregs[ESP_RSTAT] = STAT_TC | STAT_ST;
    esp_dma_done();
  }
  esp.req_active = false;
  esp.cur_tgt = -1;
}

void sun4m_t::esp_transfer_data(uint32_t len) {
  const bool to_device = ((esp.rregs[ESP_RSTAT] & 7) == STAT_DO);
  const uint32_t dmalen = esp_get_tc();
  esp.async_len = len;
  if(not to_device and not esp.data_in_ready) {
    /* the first data in: the command completion interrupt */
    esp.data_in_ready = true;
    esp.rregs[ESP_RSTAT] |= STAT_TC;
    esp.rregs[ESP_RINTR] |= INTR_BS;
    esp_raise_irq();
  }
  if(esp.ti_cmd == 0) {
    return;                  /* the next TI command moves it */
  }
  if(esp.ti_cmd == (CMD_TI | CMD_DMA)) {
    if(dmalen) {
      esp_do_dma();
    }
    else if(esp.ti_size <= 0) {
      esp_dma_done();        /* the deferred completion of the last DMA */
    }
  }
  else if(esp.ti_cmd == CMD_TI) {
    esp_do_nodma();
  }
}

void sun4m_t::esp_handle_ti() {
  if(esp.dma and not esp.dma_enabled) {
    esp.dma_cb = DMA_CB_TI;
    return;
  }
  esp.ti_cmd = esp.rregs[ESP_CMD];
  if(esp.dma) {
    esp.rregs[ESP_RSTAT] &= ~STAT_TC;
    esp_do_dma();
  }
  else {
    esp_do_nodma();
  }
}

/* qemu esp_hard_reset (the dma_enabled line belongs to the espdma) */
void sun4m_t::esp_hard_reset() {
  memset(esp.rregs, 0, sizeof(esp.rregs));
  memset(esp.wregs, 0, sizeof(esp.wregs));
  esp.tchi_written = false;
  esp.ti_size = 0;
  esp.async_len = 0;
  esp.fifo.clear();
  esp.cmdfifo.clear();
  esp.dma = false;
  esp.do_cmd = false;
  esp.dma_cb = DMA_CB_NONE;
  esp.rregs[ESP_CFG1] = 7;
}

void sun4m_t::esp_soft_reset() {
  esp.irq = false;
  esp.irq_deferred = false;
  dma_set_irq(espdma, false);
  esp_hard_reset();
}

/* every target sees the reset: a unit attention */
void sun4m_t::esp_bus_reset() {
  for(scsi_dev_t *d : scsi) {
    if(d != nullptr) {
      d->reset();
    }
  }
}

uint8_t sun4m_t::esp_read(uint32_t reg) {
  uint8_t v;
  switch(reg)
    {
    case ESP_FIFO:
      if((esp.rregs[ESP_RSTAT] & STAT_PIO_MASK) == 0) {
	esp.rregs[ESP_FIFO] = 0;   /* qemu: PIO data in/out with a DMA host is not implemented */
      }
      else {
	esp.rregs[ESP_FIFO] = fifo_pop(esp.fifo);
      }
      v = esp.rregs[ESP_FIFO];
      break;
    case ESP_RINTR:
      /* clears the interrupt register and TC (qemu leaves the sequence step) */
      v = esp.rregs[ESP_RINTR];
      esp.rregs[ESP_RINTR] = 0;
      esp.rregs[ESP_RSTAT] &= ~STAT_TC;
      esp_lower_irq();
      break;
    case ESP_TCHI:           /* the chip id until the register is written */
      v = esp.tchi_written ? esp.rregs[ESP_TCHI] : TCHI_FAS100A;
      break;
    case ESP_RFLAGS:         /* bytes in the FIFO */
      v = static_cast<uint8_t>(esp.fifo.size());
      break;
    default:
      v = esp.rregs[reg];
      break;
    }
  return v;
}

void sun4m_t::esp_write(uint32_t reg, uint8_t v) {
  switch(reg)
    {
    case ESP_TCHI:
      esp.tchi_written = true;
      /* fall through */
    case ESP_TCLO:
    case ESP_TCMID:
      esp.rregs[ESP_RSTAT] &= ~STAT_TC;
      break;
    case ESP_FIFO:
      if(esp.do_cmd) {
	fifo_push(esp.cmdfifo, ESP_CMDFIFO_SZ, v);
	/* message out / command bytes moved with a non-DMA TI: the interrupt */
	if(esp.rregs[ESP_CMD] == CMD_TI) {
	  esp.rregs[ESP_RINTR] |= INTR_BS;
	  esp_raise_irq();
	}
      }
      else {
	fifo_push(esp.fifo, ESP_FIFO_SZ, v);
      }
      break;
    case ESP_CMD:
      esp.rregs[reg] = v;
      if(v & CMD_DMA) {
	esp.dma = true;
	/* reload the transfer count from the start count (0 means 64K) */
	const uint32_t stc = esp.wregs[ESP_TCLO] | (esp.wregs[ESP_TCMID] << 8) | (esp.wregs[ESP_TCHI] << 16);
	esp_set_tc((stc == 0) ? 0x10000 : stc);
      }
      else {
	esp.dma = false;
      }
      switch(v & CMD_CMD)
	{
	case CMD_NOP:
	  break;
	case CMD_FLUSH:
	  esp.fifo.clear();
	  break;
	case CMD_RESET:
	  esp_soft_reset();
	  break;
	case CMD_BUSRESET:
	  esp_bus_reset();
	  if(not (esp.wregs[ESP_CFG1] & CFG1_RESREPT)) {
	    esp.rregs[ESP_RINTR] |= INTR_RST;
	    esp_raise_irq();
	  }
	  break;
	case CMD_TI:
	  esp_handle_ti();
	  break;
	case CMD_ICCS:
	  esp_write_response();
	  esp.rregs[ESP_RINTR] |= INTR_FC;
	  esp.rregs[ESP_RSTAT] |= STAT_MI;
	  break;
	case CMD_MSGACC:
	  esp.rregs[ESP_RINTR] |= INTR_DC;
	  esp.rregs[ESP_RSEQ] = 0;
	  esp.rregs[ESP_RFLAGS] = 0;
	  esp_raise_irq();
	  break;
	case CMD_PAD:
	  esp.rregs[ESP_RSTAT] = STAT_TC;
	  esp.rregs[ESP_RINTR] |= INTR_FC;
	  esp.rregs[ESP_RSEQ] = 0;
	  break;
	case CMD_SATN:
	case CMD_RSTATN:
	  break;
	case CMD_SEL:
	  esp_handle_s_without_atn();
	  break;
	case CMD_SELATN:
	  esp_handle_satn();
	  break;
	case CMD_SELATNS:
	  esp_handle_satn_stop();
	  break;
	case CMD_ENSEL:
	  esp.rregs[ESP_RINTR] = 0;
	  break;
	case CMD_DISSEL:
	  esp.rregs[ESP_RINTR] = 0;
	  esp_raise_irq();
	  break;
	default:
	  fprintf(stderr, "sun4m: esp: unhandled command 0x%02x\n", v);
	  break;
	}
      break;
    case ESP_WBUSID:
    case ESP_RINTR:            /* write: select/reselect timeout */
    case ESP_RSEQ:             /* write: synchronous period */
    case ESP_WSYNO:
      break;
    case ESP_CFG1:
    case ESP_CFG2:
    case ESP_CFG3:
    case ESP_RES3:
    case ESP_RES4:
      esp.rregs[reg] = v;
      break;
    case ESP_WCCF:
    case ESP_WTEST:
      break;
    default:
      return;
    }
  esp.wregs[reg] = v;
}
