#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>

#include "scsi.hh"

/* sense keys and additional sense codes used below */
enum : uint8_t {
  SK_NO_SENSE = 0x0, SK_NOT_READY = 0x2, SK_MEDIUM_ERROR = 0x3, SK_ILLEGAL_REQUEST = 0x5,
  SK_UNIT_ATTENTION = 0x6, SK_DATA_PROTECT = 0x7,
  ASC_INVALID_OPCODE = 0x20, ASC_LBA_OUT_OF_RANGE = 0x21, ASC_INVALID_FIELD = 0x24,
  ASC_LUN_NOT_SUPPORTED = 0x25, ASC_WRITE_PROTECTED = 0x27, ASC_POWER_ON = 0x29,
  ASC_SAVING_PARAMS = 0x39, ASC_READ_ERROR = 0x11, ASC_WRITE_ERROR = 0x0c
};

scsi_dev_t::scsi_dev_t(type_t t, const std::string &path) : t(t) {
  bs = (t == type_t::cdrom) ? 2048 : 512;
  if(t == type_t::disk) {
    fd = open(path.c_str(), O_RDWR);
    writable = (fd >= 0);
  }
  if(fd < 0) {
    fd = open(path.c_str(), O_RDONLY);
  }
  if(fd < 0) {
    fprintf(stderr, "scsi: cannot open '%s'\n", path.c_str());
    return;
  }
  struct stat st;
  if(fstat(fd, &st) == 0) {
    bytes = static_cast<uint64_t>(st.st_size);
  }
  set_sense(SK_NO_SENSE, 0, 0);
  fprintf(stderr, "scsi: %s '%s': %llu %u-byte blocks%s\n", (t == type_t::cdrom) ? "cdrom" : "disk",
	  path.c_str(), static_cast<unsigned long long>(nblocks()), bs, writable ? "" : " (read-only)");
}

scsi_dev_t::~scsi_dev_t() {
  if(fd >= 0) {
    close(fd);
  }
}

/* fixed-format sense data */
void scsi_dev_t::set_sense(uint8_t key, uint8_t asc, uint8_t ascq) {
  memset(sense, 0, sizeof(sense));
  sense[0] = 0x70;
  sense[2] = key;
  sense[7] = 10;
  sense[12] = asc;
  sense[13] = ascq;
}

int32_t scsi_dev_t::check(scsi_req_t &r, uint8_t key, uint8_t asc, uint8_t ascq) {
  set_sense(key, asc, ascq);
  r.buf.clear();
  r.status = 0x02;   /* CHECK CONDITION */
  return 0;
}

int32_t scsi_dev_t::data_in(scsi_req_t &r, const uint8_t *p, uint32_t n, uint32_t alloc) {
  n = std::min(n, alloc);
  r.buf.assign(p, p + n);
  r.status = 0;
  return static_cast<int32_t>(n);
}

bool scsi_dev_t::read_blocks(uint64_t lba, uint32_t n, uint8_t *dst) {
  const uint64_t len = static_cast<uint64_t>(n) * bs;
  return pread(fd, dst, len, static_cast<off_t>(lba * bs)) == static_cast<ssize_t>(len);
}

bool scsi_dev_t::write_blocks(uint64_t lba, uint32_t n, const uint8_t *src) {
  const uint64_t len = static_cast<uint64_t>(n) * bs;
  return pwrite(fd, src, len, static_cast<off_t>(lba * bs)) == static_cast<ssize_t>(len);
}

/* one mode page at p (qemu mode_sense_page: the page code, its length, then
 * the body); 0 if the device has no such page.  pc 1 asks for the changeable
 * mask: nothing is changeable but the cache enable */
uint32_t scsi_dev_t::mode_page(uint8_t page, uint8_t pc, uint8_t *p) {
  const bool disk = (t == type_t::disk);
  /* qemu's geometry guess for an image without a partition table hint */
  const uint64_t secs = 63, heads = 16;
  uint64_t cyls = nblocks() / (heads * secs);
  cyls = std::max<uint64_t>(2, std::min<uint64_t>(cyls, 16383));
  uint8_t *b = p + 2;
  uint32_t len = 0;
  switch(page)
    {
    case 0x04:                 /* rigid disk geometry */
      if(not disk) {
	return 0;
      }
      len = 0x16;
      if(pc == 1) {
	break;
      }
      b[0] = cyls >> 16; b[1] = cyls >> 8; b[2] = cyls; b[3] = heads;
      b[4] = cyls >> 16; b[5] = cyls >> 8; b[6] = cyls;   /* write precomp: disabled */
      b[7] = cyls >> 16; b[8] = cyls >> 8; b[9] = cyls;   /* reduced current: disabled */
      b[11] = 200;                                         /* step rate 200ns */
      b[12] = 0xff; b[13] = 0xff; b[14] = 0xff;            /* landing zone */
      b[18] = 5400 >> 8; b[19] = 5400 & 0xff;              /* 5400 rpm */
      break;
    case 0x05:                 /* flexible disk geometry */
      if(not disk) {
	return 0;
      }
      len = 0x1e;
      if(pc == 1) {
	break;
      }
      b[0] = 5000 >> 8; b[1] = 5000 & 0xff;                /* 5 Mbit/s */
      b[2] = heads; b[3] = secs; b[4] = bs >> 8;
      b[6] = cyls >> 8; b[7] = cyls; b[8] = cyls >> 8; b[9] = cyls; b[10] = cyls >> 8; b[11] = cyls;
      b[13] = 1; b[14] = 1; b[16] = 1; b[17] = 1; b[18] = 1;
      b[26] = 5400 >> 8; b[27] = 5400 & 0xff;
      break;
    case 0x08:                 /* caching: write cache enabled */
      len = 0x12;
      b[0] = 4;
      break;
    case 0x01:                 /* read/write error recovery */
      len = 10;
      if(pc == 1) {
	if(not disk) {
	  b[0] = 0x80;
	}
	break;
      }
      b[0] = 0x80;
      if(not disk) {
	b[1] = 0x20;
      }
      break;
    case 0x0e:                 /* CD audio control */
      if(disk) {
	return 0;
      }
      len = 14;
      break;
    case 0x2a:                 /* CD capabilities */
      if(disk) {
	return 0;
      }
      len = 0x14;
      if(pc == 1) {
	break;
      }
      b[0] = 0x3b; b[2] = 0x7f; b[3] = 0xff; b[4] = 0x2d;
      b[6] = (50 * 176) >> 8; b[7] = (50 * 176) & 0xff;
      b[9] = 2; b[10] = 2048 >> 8;
      b[12] = (16 * 176) >> 8; b[13] = (16 * 176) & 0xff;
      b[16] = (16 * 176) >> 8; b[17] = (16 * 176) & 0xff;
      b[18] = (16 * 176) >> 8; b[19] = (16 * 176) & 0xff;
      break;
    default:
      return 0;
    }
  p[0] = page;
  p[1] = static_cast<uint8_t>(len);
  return len + 2;
}

int32_t scsi_dev_t::send(uint32_t lun, const uint8_t *cdb, uint32_t len, scsi_req_t &r) {
  (void)len;
  const uint8_t op = cdb[0];
  r = scsi_req_t();
  /* only LUN 0 exists: INQUIRY says "no device here", the rest fail */
  if(lun != 0) {
    if(op == 0x12) {
      uint8_t inq[36] = {0};
      inq[0] = 0x7f;           /* peripheral qualifier 3: no device */
      inq[4] = 36 - 5;
      return data_in(r, inq, sizeof(inq), cdb[4]);
    }
    if(op == 0x03) {
      uint8_t s[18] = {0x70, 0, SK_ILLEGAL_REQUEST, 0, 0, 0, 0, 10, 0, 0, 0, 0, ASC_LUN_NOT_SUPPORTED, 0};
      return data_in(r, s, sizeof(s), cdb[4]);
    }
    return check(r, SK_ILLEGAL_REQUEST, ASC_LUN_NOT_SUPPORTED, 0);
  }
  /* a pending unit attention is the answer to anything but INQUIRY, REPORT
   * LUNS and REQUEST SENSE (which reports it) */
  if(unit_attention and op != 0x12 and op != 0xa0) {
    unit_attention = false;
    if(op != 0x03) {
      return check(r, SK_UNIT_ATTENTION, ASC_POWER_ON, 0);
    }
    set_sense(SK_UNIT_ATTENTION, ASC_POWER_ON, 0);
  }
  switch(op)
    {
    case 0x00:                 /* TEST UNIT READY */
    case 0x01:                 /* REZERO UNIT */
    case 0x04:                 /* FORMAT UNIT */
    case 0x0b:                 /* SEEK(6) */
    case 0x16:                 /* RESERVE */
    case 0x17:                 /* RELEASE */
    case 0x1b:                 /* START STOP UNIT */
    case 0x1d:                 /* SEND DIAGNOSTIC */
    case 0x1e:                 /* PREVENT ALLOW MEDIUM REMOVAL */
    case 0x2b:                 /* SEEK(10) */
    case 0x2f:                 /* VERIFY(10) */
    case 0x35:                 /* SYNCHRONIZE CACHE */
      r.status = 0;
      return 0;
    case 0x03: {               /* REQUEST SENSE: report, then clear */
      uint8_t s[sizeof(sense)];
      memcpy(s, sense, sizeof(s));
      set_sense(SK_NO_SENSE, 0, 0);
      return data_in(r, s, sizeof(s), cdb[4]);
    }
    case 0x12: {               /* INQUIRY */
      if((cdb[1] & 1) or cdb[2] != 0) {
	return check(r, SK_ILLEGAL_REQUEST, ASC_INVALID_FIELD, 0);
      }
      const bool rom = (t == type_t::cdrom);
      uint8_t inq[36] = {0};
      inq[0] = rom ? 0x05 : 0x00;
      inq[1] = rom ? 0x80 : 0x00;   /* removable */
      inq[2] = 2;                   /* SCSI-2 */
      inq[3] = 2;                   /* response data format 2 */
      inq[4] = 36 - 5;
      inq[7] = 0x10;                /* synchronous transfers */
      memcpy(inq + 8, "QEMU    ", 8);
      memcpy(inq + 16, rom ? "QEMU CD-ROM     " : "QEMU HARDDISK   ", 16);
      memcpy(inq + 32, "2.5+", 4);
      return data_in(r, inq, sizeof(inq), cdb[4]);
    }
    case 0x25: {               /* READ CAPACITY(10) */
      const uint64_t n = nblocks();
      const uint32_t last = (n == 0) ? 0 : static_cast<uint32_t>(std::min<uint64_t>(n - 1, 0xffffffffu));
      uint8_t cap[8] = {static_cast<uint8_t>(last >> 24), static_cast<uint8_t>(last >> 16),
			static_cast<uint8_t>(last >> 8), static_cast<uint8_t>(last),
			static_cast<uint8_t>(bs >> 24), static_cast<uint8_t>(bs >> 16),
			static_cast<uint8_t>(bs >> 8), static_cast<uint8_t>(bs)};
      return data_in(r, cap, sizeof(cap), sizeof(cap));
    }
    case 0x08:                 /* READ(6) */
    case 0x28: {               /* READ(10) */
      uint64_t lba;
      uint32_t n;
      if(op == 0x08) {
	lba = (static_cast<uint64_t>(cdb[1] & 0x1f) << 16) | (cdb[2] << 8) | cdb[3];
	n = cdb[4] ? cdb[4] : 256;
      }
      else {
	lba = (static_cast<uint64_t>(cdb[2]) << 24) | (cdb[3] << 16) | (cdb[4] << 8) | cdb[5];
	n = (cdb[7] << 8) | cdb[8];
      }
      if(lba + n > nblocks()) {
	return check(r, SK_ILLEGAL_REQUEST, ASC_LBA_OUT_OF_RANGE, 0);
      }
      r.status = 0;
      if(n == 0) {
	return 0;
      }
      r.buf.resize(static_cast<size_t>(n) * bs);
      if(not read_blocks(lba, n, r.buf.data())) {
	return check(r, SK_MEDIUM_ERROR, ASC_READ_ERROR, 0);
      }
      return static_cast<int32_t>(r.buf.size());
    }
    case 0x0a:                 /* WRITE(6) */
    case 0x2a: {               /* WRITE(10) */
      uint64_t lba;
      uint32_t n;
      if(op == 0x0a) {
	lba = (static_cast<uint64_t>(cdb[1] & 0x1f) << 16) | (cdb[2] << 8) | cdb[3];
	n = cdb[4] ? cdb[4] : 256;
      }
      else {
	lba = (static_cast<uint64_t>(cdb[2]) << 24) | (cdb[3] << 16) | (cdb[4] << 8) | cdb[5];
	n = (cdb[7] << 8) | cdb[8];
      }
      if(not writable) {
	return check(r, SK_DATA_PROTECT, ASC_WRITE_PROTECTED, 0);
      }
      if(lba + n > nblocks()) {
	return check(r, SK_ILLEGAL_REQUEST, ASC_LBA_OUT_OF_RANGE, 0);
      }
      r.status = 0;
      if(n == 0) {
	return 0;
      }
      r.is_write = true;
      r.wr_lba = lba;
      r.buf.assign(static_cast<size_t>(n) * bs, 0);
      return -static_cast<int32_t>(r.buf.size());
    }
    case 0x15:                 /* MODE SELECT(6) */
    case 0x55: {               /* MODE SELECT(10) */
      const uint32_t n = (op == 0x15) ? cdb[4] : ((cdb[7] << 8) | cdb[8]);
      r.status = 0;
      if(n == 0) {
	return 0;
      }
      r.is_mode_select = true;
      r.ms10 = (op == 0x55);
      r.buf.assign(n, 0);
      return -static_cast<int32_t>(n);
    }
    case 0x1a:                 /* MODE SENSE(6) */
    case 0x5a: {               /* MODE SENSE(10) */
      const bool ms6 = (op == 0x1a);
      bool dbd = (cdb[1] & 0x8) != 0;
      const uint8_t page = cdb[2] & 0x3f, pc = cdb[2] >> 6;
      const uint32_t alloc = ms6 ? cdb[4] : ((cdb[7] << 8) | cdb[8]);
      uint8_t out[1024] = {0};
      uint8_t dev_specific = 0;
      if(t == type_t::disk) {
	dev_specific = writable ? 0x00 : 0x80;
      }
      else {
	dbd = true;            /* MMC: no block descriptors */
      }
      uint8_t *p = out;
      if(ms6) {
	p[2] = dev_specific;
	p += 4;
      }
      else {
	p[3] = dev_specific;
	p += 8;
      }
      if(not dbd and nblocks() != 0) {
	uint64_t n = nblocks();
	if(n > 0xffffff) {
	  n = 0;
	}
	if(ms6) {
	  out[3] = 8;
	}
	else {
	  out[7] = 8;
	}
	p[1] = n >> 16; p[2] = n >> 8; p[3] = n;
	p[6] = bs >> 8;
	p += 8;
      }
      if(pc == 3) {
	return check(r, SK_ILLEGAL_REQUEST, ASC_SAVING_PARAMS, 0);
      }
      if(page == 0x3f) {
	for(uint8_t pg = 0; pg <= 0x3e; pg++) {
	  p += mode_page(pg, pc, p);
	}
      }
      else {
	const uint32_t n = mode_page(page, pc, p);
	if(n == 0) {
	  return check(r, SK_ILLEGAL_REQUEST, ASC_INVALID_FIELD, 0);
	}
	p += n;
      }
      const uint32_t buflen = static_cast<uint32_t>(p - out);
      if(ms6) {
	out[0] = static_cast<uint8_t>(buflen - 1);
      }
      else {
	out[0] = static_cast<uint8_t>((buflen - 2) >> 8);
	out[1] = static_cast<uint8_t>(buflen - 2);
      }
      return data_in(r, out, buflen, alloc);
    }
    case 0x37: {               /* READ DEFECT DATA(10): an empty list */
      uint8_t d[4] = {0, static_cast<uint8_t>(cdb[2] & 0x1f), 0, 0};
      return data_in(r, d, sizeof(d), (cdb[7] << 8) | cdb[8]);
    }
    case 0x43: {               /* READ TOC: one data track */
      if(t != type_t::cdrom) {
	return check(r, SK_ILLEGAL_REQUEST, ASC_INVALID_OPCODE, 0);
      }
      const bool msf = (cdb[1] & 2) != 0;
      const uint8_t fmt = cdb[9] >> 6 ? (cdb[9] >> 6) : (cdb[2] & 0xf);
      const uint32_t alloc = (cdb[7] << 8) | cdb[8];
      auto addr = [&](uint8_t *q, uint32_t lba) {
	if(msf) {
	  const uint32_t f = lba + 150;
	  q[0] = 0; q[1] = f / (75 * 60); q[2] = (f / 75) % 60; q[3] = f % 75;
	}
	else {
	  q[0] = lba >> 24; q[1] = lba >> 16; q[2] = lba >> 8; q[3] = lba;
	}
      };
      uint8_t toc[20] = {0};
      if(fmt == 0) {           /* track 1 and the lead-out */
	toc[1] = 18; toc[2] = 1; toc[3] = 1;
	toc[5] = 0x14; toc[6] = 1; addr(toc + 8, 0);
	toc[13] = 0x14; toc[14] = 0xaa; addr(toc + 16, static_cast<uint32_t>(nblocks()));
	return data_in(r, toc, 20, alloc);
      }
      if(fmt == 1) {           /* session information: one session */
	toc[1] = 10; toc[2] = 1; toc[3] = 1;
	toc[5] = 0x14; toc[6] = 1; addr(toc + 8, 0);
	return data_in(r, toc, 12, alloc);
      }
      return check(r, SK_ILLEGAL_REQUEST, ASC_INVALID_FIELD, 0);
    }
    case 0xa0: {               /* REPORT LUNS: LUN 0 */
      uint8_t l[16] = {0, 0, 0, 8};
      return data_in(r, l, sizeof(l), (cdb[6] << 24) | (cdb[7] << 16) | (cdb[8] << 8) | cdb[9]);
    }
    default:
      fprintf(stderr, "scsi: unhandled CDB opcode 0x%02x\n", op);
      return check(r, SK_ILLEGAL_REQUEST, ASC_INVALID_OPCODE, 0);
    }
}

/* the data-out buffer is full: commit a WRITE */
void scsi_dev_t::finish_out(scsi_req_t &r) {
  if(r.is_write and not write_blocks(r.wr_lba, static_cast<uint32_t>(r.buf.size() / bs), r.buf.data())) {
    check(r, SK_MEDIUM_ERROR, ASC_WRITE_ERROR, 0);
  }
  /* MODE SELECT: only a CD-ROM's block descriptor is honored -- its block length
   * picks 512- or 2048-byte blocks.  Sun's CD-ROM drives run in 512-byte mode
   * and Solaris 2.5.1's sd selects it (a 2048-byte answer to its 1-block READ
   * is a DMA overrun and "cannot mount root"); other pages are ignored. */
  if(r.is_mode_select and t == type_t::cdrom) {
    const size_t hdr = r.ms10 ? 8 : 4;
    const uint32_t bdl = r.ms10 ? ((r.buf.size() > 7) ? ((r.buf[6] << 8) | r.buf[7]) : 0)
                                : ((r.buf.size() > 3) ? r.buf[3] : 0);
    if(bdl >= 8 and r.buf.size() >= hdr + 8) {
      const uint8_t *d = &r.buf[hdr];
      const uint32_t len = (d[5] << 16) | (d[6] << 8) | d[7];
      if(len == 512 or len == 2048) {
	if(len != bs) {
	  fprintf(stderr, "scsi: cdrom block size %u -> %u (MODE SELECT)\n", bs, len);
	}
	bs = len;
      }
    }
  }
}
