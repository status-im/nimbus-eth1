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

/* zisk v1.4.0-alpha `core/src/mem.rs`:
 *
 *   ROM_ADDR           0x90000000  ROM_SIZE 0x08000000      program code
 *   ZISKLIB_ROM_ADDR   0x97e00000                           ZisK lib, 1M
 *   FLOAT_LIB_ROM_ADDR 0x97f00000                           soft-float lib, top 1M
 *   RAM_ADDR           0xa0000000  RAM_SIZE 0x20000000
 *     STACK_ADDR       0xa0000000  STACK_SIZE 0x400000      zisk stack, unused here
 *     SYS_ADDR         0xa0400000  SYS_SIZE 0x10000         registers, UART, CSRs
 *     OUTPUT_ADDR      0xa0410000  OUTPUT_MAX_SIZE 0x20000  public output
 *     GENERAL_RAM_ADDR 0xa0430000
 *   ZISKLIB_RAM_ADDR   0xbffc0000                           ZisK lib, 192K
 *   FLOAT_LIB_RAM_ADDR 0xbfff0000                           soft-float lib, top 64K
 *
 *   rom = [ROM_ADDR, ZISKLIB_ROM_ADDR)         = 0x07e00000 bytes
 *   ram = [GENERAL_RAM_ADDR, ZISKLIB_RAM_ADDR) = 0x1fb90000 bytes
 */
MEMORY
{
  rom (rx)  : ORIGIN = 0x90000000, LENGTH = 0x07e00000
  ram (rw)  : ORIGIN = 0xa0430000, LENGTH = 0x1fb90000
}

/* The standard builds the loaded image from the program headers rather than
 * the section headers, and requires W^X. An executable segment is then either
 * PF_X or PF_X|PF_R, and a zkVM takes only one of the two. ZisK takes PF_X,
 * warning "execute-and-not-read" on anything else, since it initialises every
 * readable ROM word into the memory trace: a readable `.text` pays for the
 * whole image as data that is never loaded.
 *
 * So `.text` must hold instructions and nothing the program reads, which the
 * standard asks be confirmed post-link. Done for this build.
 */
PHDRS
{
  text   PT_LOAD FLAGS(1); /* --x */
  rodata PT_LOAD FLAGS(4); /* r-- */
  data   PT_LOAD FLAGS(6); /* rw- */
  bss    PT_LOAD FLAGS(6); /* rw- */
}

/* The guest recurses through trie and RLP code. No guard page: overflow runs
 * into .bss. */
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

    /* Constructor/destructor tables. ziskos's `_zisk_main` walks them, so the
     * bounds must be defined. Input sections carry SHF_WRITE: any entry makes
     * .rodata writable and ZisK rejects the ELF. */
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

  /* `_heap_start`/`_heap_end`: standard-mandated names, used by newlib's _sbrk.
   * The staticlib allocates from its own buffer in .bss. */
  . = ALIGN(16);
  PROVIDE(_heap_start = .);
  PROVIDE(_heap_end   = ORIGIN(ram) + LENGTH(ram));

  _end = .;

  /DISCARD/ :
  {
    *(.comment)
    *(.note .note.*)
    *(.riscv.attributes)
  }
}
