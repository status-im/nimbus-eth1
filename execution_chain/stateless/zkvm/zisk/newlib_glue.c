/* Nimbus
 * Copyright (c) 2026 Status Research & Development GmbH
 * Licensed under either of
 *  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
 *  * MIT license ([LICENSE-MIT](LICENSE-MIT))
 * at your option.
 * This file may not be copied, modified, or distributed except according to
 * those terms.
 */

/* Platform layer for a ZisK guest linked against newlib.
 *
 * newlib supplies malloc, the string and stdio families and the rest of the C
 * library. this file supplies the syscalls beneath it.
 *
 * Everything here is required: without it the guest either fails to link or
 * fails to run.
 *
 * Syscalls not defined here come from -lnosys, which fails them with ENOSYS and
 * warns at link time. The link must therefore use -nostdlib and name its
 * libraries explicitly, or the driver pulls in libgloss instead, whose versions
 * issue `ecall` to a Linux kernel that a zkVM does not have.
 */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/* --- heap ---------------------------------------------------------------
 *
 * `_heap_start` and `_heap_end` come from the linker script and are the two
 * symbols the zkevm-standards `static-library-and-linker-script` standard
 * mandates, "which applications may use to implement a custom heap allocator":
 * https://github.com/eth-act/zkevm-standards/blob/a87de83c494b1f02f7f8edd94a80e46233b46e82/standards/static-library-and-linker-script/README.md#L66
 *
 * A bump pointer is all newlib's malloc needs underneath: it does its own
 * free-list management on top, so freed blocks are reused within the region we
 * hand out and the footprint tracks live memory rather than total allocation.
 *
 */

extern char _heap_start[];
extern char _heap_end[];

static char *heap_pos = _heap_start;

void *_sbrk(ptrdiff_t incr) {
  /* -1, not NULL: that is sbrk's failure convention and what newlib checks. */
  if (incr > 0 && incr > _heap_end - heap_pos) {
    errno = ENOMEM;
    return (void *)-1;
  }

  /* sbrk returns the base of the newly available bytes, which is the break as
   * it was before the increment */
  char *base = heap_pos;
  heap_pos += incr;
  return base;
}

/* --- output --------------------------------------------------------------
 *
 * Routed at the vendor's sys_write so a guest under an emulator can print. Not
 * the public output channel, that is write_output. printf cannot be used here:
 * stdio never initialises, so it faults before printing anything.
 */

extern void sys_write(uint32_t fd, const uint8_t *ptr, size_t nbytes);

ssize_t _write(int fd, const void *buf, size_t count) {
  if (count > 0)
    sys_write((uint32_t)fd, (const uint8_t *)buf, count);

  /* Claim everything was written: sys_write cannot report a short write. */
  return (ssize_t)count;
}

/* --- termination ---------------------------------------------------------
 *
 * Defining these keeps newlib's exit machinery out of the link and supplies the
 * only termination that works here. Removing leaves the guest spinning forever
 * on libnosys's `_exit`.
 *
 * None of it runs in a normal execution: the vendor's `_start` tail-calls
 * `main` via `_zisk_main`, and halts itself once `main` returns. These matter
 * only when something calls exit() instead of returning.
 */

/* Issues a standard RISC-V `ecall` with a7 = 93 (Linux exit syscall number) and
 * the exit code in a0. ZisK intercepts this and finalises the proof. The
 * mechanism is ZisK's own. The standards mandate that a guest halts and reports
 * failure, but leave how to do it to each zkVM.
 *
 * Not `__builtin_trap()`: that compiles to `ebreak`, which ZisK does not treat
 * as fatal, so execution would run straight past it. */
__attribute__((noreturn)) static void zkvm_halt(uint8_t code) {
  register uint64_t a0 asm("a0") = code;
  register uint64_t a7 asm("a7") = 93;
  asm volatile("ecall" : : "r"(a0), "r"(a7) : "memory");
  __builtin_unreachable();
}

int atexit(void (*fn)(void)) {
  (void)fn; /* discarded: nothing runs handlers, but failing stops startup */
  return 0;
}

void exit(int status) {
  zkvm_halt((uint8_t)status);
}

/* Separate from exit because newlib calls this one directly, bypassing it. */
void _exit(int status) {
  zkvm_halt((uint8_t)status);
}

/* --- atomics -------------------------------------------------------------
 *
 * The ZisK ISA is rv64im: integer and multiply/divide, no A extension. gcc
 * therefore lowers the std/atomics aristo uses into __atomic_* libcalls, which
 * nothing in the link provides. The guest is single-core and --threads:off, so
 * there is nothing to be atomic against and a plain read-modify-write is the
 * correct implementation rather than a shortcut.
 *
 * Weak, so a toolchain that does supply them wins instead.
 */

__attribute__((weak)) uint64_t __atomic_fetch_add_8(
    volatile void *ptr, uint64_t val, int memorder) {
  (void)memorder; /* ordering is meaningless on a single thread */

  /* volatile carried through from the parameter type: casting it away would
   * discard a qualifier the caller declared. */
  uint64_t old = *(volatile uint64_t *)ptr;
  *(volatile uint64_t *)ptr = old + val;

  return old;
}

/* --- pthreads ------------------------------------------------------------
 *
 * chronicles' topics_registry and nim-metrics make Nim emit pthread_mutex_*
 * calls even at --threads:off. newlib's <pthread.h> declares nothing unless
 * _POSIX_THREADS is set, so the guest build sets it. newlib has no thread
 * implementation behind it, so the definitions are left to us.
 *
 * There is nothing to lock against, so these do nothing and report success.
 *
 * TODO: look into keeping pthread_mutex_* out of the build entirely.
 */

#include <pthread.h>

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a) {
  (void)m; (void)a;
  return 0;
}

int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_lock(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_unlock(pthread_mutex_t *m) { (void)m; return 0; }
