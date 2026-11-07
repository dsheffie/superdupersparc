#ifndef __SCSI_HH__
#define __SCSI_HH__

#include <cstdint>
#include <string>
#include <vector>

/* A SCSI-2 target on the sun4m ESP's bus: a direct-access disk or a CD-ROM
 * backed by a raw image file.  The command set and the data it returns follow
 * qemu 8.2's scsi-hd / scsi-cd (hw/scsi/scsi-disk.c), but the device claims
 * SCSI-2, as the SS-20's era of OBP, Solaris 2 and NeXTSTEP expects: no REPORT
 * LUNS / VPD / READ CAPACITY(16) traffic, and LUNs past 0 report "not present".
 * Every command completes synchronously (qemu's emulated commands already do;
 * its READ/WRITE only differ in when the data arrives).
 *
 * The request protocol mirrors qemu's scsi_req_enqueue / scsi_req_continue:
 * send() returns the data length (> 0 data in, < 0 data out, 0 none, in which
 * case the command is already complete); the controller moves req.buf and
 * calls finish_out() once a data-out buffer is full. */

struct scsi_req_t {
  std::vector<uint8_t> buf;    /* data in: what the target returns; data out: what it receives */
  uint8_t status = 0;          /* SCSI status byte: 0x00 GOOD, 0x02 CHECK CONDITION */
  /* a pending WRITE (committed by finish_out) */
  bool is_write = false;
  uint64_t wr_lba = 0;
  /* a pending MODE SELECT (6 or 10): finish_out parses its block descriptor */
  bool is_mode_select = false;
  bool ms10 = false;
};

class scsi_dev_t {
public:
  enum class type_t { disk, cdrom };
  scsi_dev_t(type_t t, const std::string &path);
  ~scsi_dev_t();
  bool ok() const { return fd >= 0; }
  type_t type() const { return t; }
  /* the target's state that a checkpoint carries */
  uint8_t sense[18] = {0};
  bool unit_attention = true;  /* power-on reset, reported once (qemu: SENSE_CODE(POWER_ON)) */
  uint32_t bs = 512;           /* the block size: a CD-ROM's MODE SELECT switches 2048 <-> 512 */
  /* a CD-ROM's block size at power-on and after a reset: 2048, or 512 (ss10sim
   * --cdrom-bs) as Sun-firmware drives, which Solaris 2.5.1 assumes */
  uint32_t power_on_bs = 2048;
  /* a SCSI bus reset or a device reset */
  void reset() {
    unit_attention = true;
    if(t == type_t::cdrom) {
      bs = power_on_bs;
    }
  }
  int32_t send(uint32_t lun, const uint8_t *cdb, uint32_t len, scsi_req_t &r);
  void finish_out(scsi_req_t &r);
private:
  type_t t;
  int fd = -1;
  uint64_t bytes = 0;
  bool writable = false;
  uint64_t nblocks() const { return bytes / bs; }
  void set_sense(uint8_t key, uint8_t asc, uint8_t ascq);
  int32_t check(scsi_req_t &r, uint8_t key, uint8_t asc, uint8_t ascq);
  int32_t data_in(scsi_req_t &r, const uint8_t *p, uint32_t n, uint32_t alloc);
  bool read_blocks(uint64_t lba, uint32_t n, uint8_t *dst);
  bool write_blocks(uint64_t lba, uint32_t n, const uint8_t *src);
  uint32_t mode_page(uint8_t page, uint8_t pc, uint8_t *p);
};

#endif
