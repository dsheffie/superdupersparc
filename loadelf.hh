#include <list>
#include <functional>
#include "interpret.hh"

#ifndef __LOAD_ELF_H__
#define __LOAD_ELF_H__

void load_elf(const char* fn, state_t *ms);
/* Walk a big-endian ELF32's PT_LOAD segments: f(vaddr, file bytes, filesz,
 * memsz) for each.  *entry = e_entry, *total = the sum of memsz (qemu's
 * load_elf return value).  False if the file is not a SPARC ELF. */
bool for_each_elf_segment(const char *fn,
			  const std::function<void(uint32_t, const uint8_t *, uint32_t, uint32_t)> &f,
			  uint32_t *entry, uint64_t *total);

#endif 

