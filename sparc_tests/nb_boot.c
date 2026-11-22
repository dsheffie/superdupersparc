/* nb_boot: NetBSD/sparc's real first- and second-stage boot (bootxx from the
 * disk's boot block, /boot's blocks from its FFS) on ooo_core under a minimal
 * fake OBP, so the checker compares every instruction of the path that fails on
 * Kodiak (a stale L1I line at 0x4020: bootxx runs at 0x4000, relocates itself to
 * 0x300000 reading its own code as data, memcpy's /boot over 0x4000 and jumps
 * there; /boot's srt0 first differs from bootxx's at 0x4028).
 *
 * What OBP does that matters here: copy the boot block's text to 0x4000 with CPU
 * stores, and call it with %o0 = the romvec (v2).  bootxx (built -DBOOTXX) uses
 * only the romvec header, nodeops (read, not called), v2_bootargs, and
 * v2_devops open/read/seek/close.  Disk reads here are CPU copies from the blob
 * (OBP's are ESP DMA).  The first write -- /boot's banner -- ends the test.
 *
 * Linked with sv_asm.S (trap table, window spill/fill, ET=1); nb_blobs.S
 * .incbin's build/nb_bootxx.bin (the boot block minus its a.out header) and
 * build/nb_boot_blocks.bin (/boot's blocks, in bootxx's block-table order).
 * Build + run: nb_boot.sh. */
#define __dead
typedef unsigned int u_int;
#include "bsd_openprom.h"   /* NetBSD sys/arch/sparc/include, netbsd-10 */

extern const unsigned char nb_bootxx[], nb_bootxx_end[];
extern const unsigned char nb_boot_blocks[], nb_boot_blocks_end[];

static unsigned g_rd_off;     /* next byte of nb_boot_blocks a read returns */
static unsigned g_reads, g_seeks;

static void halt(void) {
  asm volatile("ta 0x7f" ::: "memory");   /* sv_asm.S: clean exit */
  for(;;) {
  }
}

static void copy_bytes(void *dst, const void *src, unsigned n) {
  volatile unsigned char *d = dst;
  const volatile unsigned char *s = src;
  for(unsigned i = 0; i < n; i++) {
    d[i] = s[i];
  }
}

static int obp_open(const char *path) {
  (void)path;
  return 1;
}
static void obp_close(int fd) {
  (void)fd;
}
static int obp_read(int fd, void *buf, int len) {
  (void)fd;
  unsigned avail = (unsigned)(nb_boot_blocks_end - nb_boot_blocks) - g_rd_off;
  unsigned n = (unsigned)len < avail ? (unsigned)len : avail;
  copy_bytes(buf, nb_boot_blocks + g_rd_off, n);
  g_rd_off += n;
  g_reads++;
  return (int)n;
}
static int obp_write(int fd, const void *buf, int len) {
  (void)fd;
  (void)buf;
  (void)len;
  halt();     /* /boot's banner: it is running, the test is over */
  return len;
}
static void obp_seek(int fd, int hi, int lo) {
  (void)fd;
  (void)hi;
  (void)lo;
  g_seeks++;  /* bootxx reads its block table in order: reads are sequential */
}
static int no_node(int n) {
  (void)n;
  return 0;
}
static int no_proplen(int n, const char *name) {
  (void)n;
  (void)name;
  return -1;
}
static int no_getprop(int n, const char *name, void *buf) {
  (void)n;
  (void)name;
  (void)buf;
  return -1;
}
static void obp_halt(void) {
  halt();
}

static struct nodeops g_nodeops = {
  no_node, no_node, no_proplen, no_getprop, 0, 0
};
static char g_bootpath_s[] = "/iommu/sbus/espdma/esp/sd@3,0:a";
static char g_bootargs_s[] = "";
static char *g_bootpath = g_bootpath_s;
static char *g_bootargs = g_bootargs_s;
static int g_fd0 = 0, g_fd1 = 1;
static int g_ticks;
static struct promvec g_romvec;

int main(void) {
  g_romvec.pv_magic = OBP_MAGIC;
  g_romvec.pv_romvec_vers = 2;
  g_romvec.pv_printrev = 0x20019;
  g_romvec.pv_nodeops = &g_nodeops;
  g_romvec.pv_ticks = &g_ticks;
  g_romvec.pv_halt = obp_halt;
  g_romvec.pv_abort = obp_halt;
  g_romvec.pv_v2bootargs.v2_bootpath = &g_bootpath;
  g_romvec.pv_v2bootargs.v2_bootargs = &g_bootargs;
  g_romvec.pv_v2bootargs.v2_fd0 = &g_fd0;
  g_romvec.pv_v2bootargs.v2_fd1 = &g_fd1;
  g_romvec.pv_v2devops.v2_open = obp_open;
  g_romvec.pv_v2devops.v2_close = obp_close;
  g_romvec.pv_v2devops.v2_read = obp_read;
  g_romvec.pv_v2devops.v2_write = obp_write;
  g_romvec.pv_v2devops.v2_seek = obp_seek;
  /* OBP: the boot block's text to 0x4000 by CPU stores */
  copy_bytes((void *)0x4000, nb_bootxx, (unsigned)(nb_bootxx_end - nb_bootxx));
  void (*entry)(void *) = (void (*)(void *))0x4000;
  entry(&g_romvec);
  return 1;   /* bootxx returned: _rtt */
}
