/*
 * fishhook - Facebook 出品的轻量级动态符号重绑定工具
 * 用于替换懒加载符号表中的函数指针
 */

#include "fishhook.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#endif

static struct rebinding *_rebindings = NULL;
static size_t _rebindings_nel = 0;

static int cmp_rebinding(const void *a, const void *b) {
  const struct rebinding *ra = (const struct rebinding *)a;
  const struct rebinding *rb = (const struct rebinding *)b;
  return strcmp(ra->name, rb->name);
}

static void rebind_symbols_for_image(const struct mach_header *header,
                                     intptr_t slide) {
  if (header->magic != MH_MAGIC_64) return;

  const segment_command_t *seg_linkedit = NULL;
  const segment_command_t *seg_data = NULL;
  const struct dysymtab_command *dysymtab = NULL;
  const struct symtab_command *symtab = NULL;

  const struct load_command *lc = (const struct load_command *)((const char *)header + sizeof(mach_header_t));
  for (uint32_t i = 0; i < header->ncmds; i++) {
    if (lc->cmd == LC_SEGMENT_64) {
      const segment_command_t *seg = (const segment_command_t *)lc;
      if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
        seg_linkedit = seg;
      } else if (strcmp(seg->segname, SEG_DATA) == 0) {
        seg_data = seg;
      }
    } else if (lc->cmd == LC_SYMTAB) {
      symtab = (const struct symtab_command *)lc;
    } else if (lc->cmd == LC_DYSYMTAB) {
      dysymtab = (const struct dysymtab_command *)lc;
    }
    lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
  }

  if (!seg_linkedit || !seg_data || !symtab || !dysymtab) return;

  uintptr_t linkedit_base = (uintptr_t)slide + seg_linkedit->vmaddr - seg_linkedit->fileoff;
  const char *strtab = (const char *)(linkedit_base + symtab->stroff);
  const nlist_t *symtab_entries = (const nlist_t *)(linkedit_base + symtab->symoff);

  // 遍历 __DATA 段中的所有 section，找懒加载符号指针
  const section_t *sections = (const section_t *)(seg_data + 1);
  for (uint32_t j = 0; j < seg_data->nsects; j++) {
    if ((sections[j].flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS) {
      // 找到懒加载符号指针段
      uint32_t *lazy_pointers = (uint32_t *)(slide + sections[j].addr);
      uint32_t indirect_sym_index = sections[j].reserved1;
      uint32_t num_pointers = sections[j].size / sizeof(uint64_t); // 64位

      for (uint32_t k = 0; k < num_pointers; k++) {
        uint32_t sym_index = ((uint32_t *)(linkedit_base + dysymtab->indirectsymoff))[indirect_sym_index + k];
        if (sym_index == INDIRECT_SYMBOL_ABS || sym_index == INDIRECT_SYMBOL_LOCAL) continue;

        const char *sym_name = strtab + symtab_entries[sym_index].n_un.n_strx;
        // 跳过前导下划线
        if (*sym_name == '_') sym_name++;

        // 二分查找匹配的 rebinding
        struct rebinding key = { .name = sym_name };
        struct rebinding *found = bsearch(&key, _rebindings, _rebindings_nel,
                                          sizeof(struct rebinding), cmp_rebinding);
        if (found) {
          // 替换指针
          uint64_t *ptr = (uint64_t *)lazy_pointers + k;
          if (found->replaced) {
            *(found->replaced) = (void *)*ptr;
          }
          *ptr = (uint64_t)found->replacement;
        }
      }
    }
  }
}

static void _dyld_callback(const struct mach_header *mh, intptr_t vmaddr_slide, void *context) {
  (void)context;
  rebind_symbols_for_image(mh, vmaddr_slide);
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
  _rebindings = (struct rebinding *)realloc(_rebindings, (_rebindings_nel + rebindings_nel) * sizeof(struct rebinding));
  memcpy(_rebindings + _rebindings_nel, rebindings, rebindings_nel * sizeof(struct rebinding));
  _rebindings_nel += rebindings_nel;

  // 按名称排序，用于二分查找
  qsort(_rebindings, _rebindings_nel, sizeof(struct rebinding), cmp_rebinding);

  // 注册 dyld 回调，处理已加载和未来加载的镜像
  _dyld_register_func_for_add_image(&_dyld_callback, NULL);

  return 0;
}

int rebind_symbols_image(void *header,
                         intptr_t slide,
                         struct rebinding rebindings[],
                         size_t rebindings_nel) {
  struct rebinding *old_rebindings = _rebindings;
  size_t old_nel = _rebindings_nel;

  _rebindings = rebindings;
  _rebindings_nel = rebindings_nel;
  qsort(_rebindings, _rebindings_nel, sizeof(struct rebinding), cmp_rebinding);

  rebind_symbols_for_image((const struct mach_header *)header, slide);

  _rebindings = old_rebindings;
  _rebindings_nel = old_nel;

  return 0;
}
