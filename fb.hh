#ifndef __FB_HH__
#define __FB_HH__

#include <cstdint>

/* what the display (display.hh) needs from a framebuffer device */
struct framebuffer_t {
  uint64_t gen = 0;                            /* bumped on every visible change */
  virtual ~framebuffer_t() {}
  virtual uint32_t width() const = 0;
  virtual uint32_t height() const = 0;
  /* the visible screen as 0x00RRGGBB, width() * height(), cursor included */
  virtual void render(uint32_t *out) const = 0;
};

#endif
