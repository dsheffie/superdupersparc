#ifndef __CKPT_HH__
#define __CKPT_HH__

class state_t;

/* Full-system checkpoints (ss10sim writes them, the ooo_core harness restores
 * them): the architectural state, the sun4m devices (with the time base) and
 * the non-zero RAM pages.  A boost binary archive: the same build reads what it
 * wrote; a version mismatch is refused. */
bool save_checkpoint(const char *fn, const state_t *s);
/* s->mem is cleared and refilled; s->sun4m is allocated if the checkpoint has
 * devices and s has none */
bool load_checkpoint(const char *fn, state_t *s);

#endif
