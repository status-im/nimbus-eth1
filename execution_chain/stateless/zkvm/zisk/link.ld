/* Nimbus
 * Copyright (c) 2026 Status Research & Development GmbH
 * Licensed under either of
 *  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
 *  * MIT license ([LICENSE-MIT](LICENSE-MIT))
 * at your option.
 * This file may not be copied, modified, or distributed except according to
 * those terms.
 */

/* Linker script for the stateless guest on ZisK.
 *
 * The `static-library-and-linker-script` standard says the *vendor* supplies this.
 * ZisK ships none for guests, so this is ours until upstream provides one.
 */

OUTPUT_FORMAT("elf64-littleriscv")
OUTPUT_ARCH("riscv")
ENTRY(_start)

/* Addresses come from zisk `core/src/mem.rs`:
 *
 *   ROM_ADDR           0x80000000  ROM_SIZE 0x08000000 (128M)  program code
 *   FLOAT_LIB_ROM_ADDR 0x87f00000                              top 1M, soft-float lib
 *   RAM_ADDR           0xa0000000  RAM_SIZE 0x20000000 (512M)
 *     SYS_ADDR         0xa0000000  SYS_SIZE 0x10000            reserved: UART, CSRs
 *     OUTPUT_ADDR      0xa0010000  ..0xa0030000                public output
 *     AVAILABLE_MEM    0xa0030000                              general purpose RW
 *   FLOAT_LIB_RAM_ADDR 0xbfff0000                              top 64K, soft-float lib
 *
 * The soft-float library reserves space at the top of *both*, so code lives in
 * [0x80000000, 0x87f00000) and writable data in [0xa0030000, 0xbfff0000). Both
 * lengths below are those spans:
 *
 *   FLOAT_LIB_ROM_ADDR - ROM_ADDR           = 0x87f00000 - 0x80000000
 *                                           = 0x07f00000
 *   FLOAT_LIB_RAM_ADDR - AVAILABLE_MEM_ADDR = 0xbfff0000 - 0xa0030000
 *                                           = 0x1ffc0000
 *
 * Computed here rather than taken from zisk's AVAILABLE_MEM_SIZE, which is not
 * that span: it subtracts only SYS_SIZE and OUTPUT_MAX_SIZE, leaves the
 * soft-float reserve out entirely, and from AVAILABLE_MEM_ADDR would run
 * 0x20000 past the end of RAM. Nothing in zisk reads it, so it is not a bound
 * to rely on.
 */
MEMORY
{
  rom (rx)  : ORIGIN = 0x80000000, LENGTH = 0x07f00000
  ram (rw)  : ORIGIN = 0xa0030000, LENGTH = 0x1ffc0000
}

/* The standard's only hard rule here is W^X: no segment both writable and
 * executable. Read-only data is allowed to share the executable segment
 * (PF_X|PF_R), so the separate rodata segment below is not required. But it
 * is cleaner as it leaves .rodata out of executable memory, which some zkVM
 * might demand anyway.
 *
 * ZisK ignores this block: its loader (`core/src/elf_extraction.rs`) builds the
 * memory image from section flags, which the standard forbids. So the PHDRS are
 * for conformance only, here the section flags decide.
 */
PHDRS
{
  text   PT_LOAD FLAGS(5); /* r-x */
  rodata PT_LOAD FLAGS(4); /* r-- */
  data   PT_LOAD FLAGS(6); /* rw- */
  bss    PT_LOAD FLAGS(6); /* rw- */
}

/* Stack size. The guest recurses through trie and RLP code, and unlike a hosted
 * process there is no guard page and no growth thus overflow silently walks into the
 * heap. Generous on purpose as RAM is 512M */
__stack_size = 8M;

SECTIONS
{
  .text : ALIGN(4)
  {
    *(.text.init)          /* zisk's `_start` is #[link_section = ".text.init"] */
    *(.text .text.*)
  } >rom :text

  .rodata : ALIGN(8)
  {
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
    *(.eh_frame .eh_frame.*)
    *(.gcc_except_table .gcc_except_table.*)
    *(.data.rel.ro .data.rel.ro.*)

    /* C constructor/destructor tables: arrays of function pointers, walked at
     * startup by a loop that calls each one. Empty here, and they must stay
     * empty, because nothing on this target walks them. ZisK's loader skips
     * SHT_INIT_ARRAY and `_zisk_main` tail-calls `main` without iterating, so
     * any constructor listed here would simply never be called.
     *
     * Keeping them in ROM turns that into a loud failure. They carry SHF_WRITE,
     * and an output section takes the union of its inputs' flags, so anything
     * landing here makes .rodata writable inside ROM and ZisK rejects the ELF
     * at load. */
    . = ALIGN(8);
    PROVIDE_HIDDEN(__preinit_array_start = .);
    KEEP(*(.preinit_array))
    PROVIDE_HIDDEN(__preinit_array_end = .);

    . = ALIGN(8);
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
    KEEP(*(.init_array))
    PROVIDE_HIDDEN(__init_array_end = .);

    . = ALIGN(8);
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*)))
    KEEP(*(.fini_array))
    PROVIDE_HIDDEN(__fini_array_end = .);
  } >rom :rodata

  .data : ALIGN(8)
  {
    *(.data .data.*)
    /* zisk's `_start` does `la gp, _global_pointer`, so the name has to exist.
     * gp-relative offsets are signed 12-bit, so anchoring 0x800 into the small
     * data puts 4K of it within reach of one instruction instead of 2K. That
     * offset is the psABI convention, and what ld's own script uses.
     *
     * TODO: `__global_pointer$` is undefined, so ld skips gp relaxation and
     * nothing actually addresses through gp today. */
    . = ALIGN(8);
    PROVIDE(_global_pointer = . + 0x800);
    *(.sdata .sdata.* .sdata2 .sdata2.*)
  } >ram :data

  .bss (NOLOAD) : ALIGN(8)
  {
    PROVIDE(_bss_start = .);
    *(.sbss .sbss.* .scommon)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(8);
    PROVIDE(_bss_end = .);
  } >ram :bss

  . = ALIGN(16);

  /* zisk's `_start` does `la sp, _init_stack_top`. Grows down from there, so the
   * heap placed above can never clobber stack frames. */
  . = . + __stack_size;
  PROVIDE(_init_stack_top = .);

  /* Heap: all remaining RAM, under two pairs of names for the same bytes.
   * `_heap_start`/`_heap_end` are the ones the standard mandates. zisk's
   * `init_sys_alloc` (`ziskos/entrypoint/src/alloc/alloc.rs`) reads
   * `_kernel_heap_bottom`/`_top` instead, and the link fails without them.
   *
   * Same bytes on purpose, but only one allocator may hand them out: newlib's
   * malloc through _sbrk. zisk's own allocator is never called. */
  . = ALIGN(16);
  PROVIDE(_heap_start          = .);
  PROVIDE(_kernel_heap_bottom  = .);

  PROVIDE(_heap_end            = ORIGIN(ram) + LENGTH(ram));
  PROVIDE(_kernel_heap_top     = ORIGIN(ram) + LENGTH(ram));

  _end = .;

  /DISCARD/ :
  {
    *(.comment)
    *(.note .note.*)
    *(.riscv.attributes)
  }
}
