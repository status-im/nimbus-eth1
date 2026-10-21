/* Nimbus
 * Copyright (c) 2026 Status Research & Development GmbH
 * Licensed under either of
 *  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
 *  * MIT license ([LICENSE-MIT](LICENSE-MIT))
 * at your option.
 * This file may not be copied, modified, or distributed except according to
 * those terms.
 */

/* Platform layer for an SP1 guest linked against newlib.
 *
 * libzkevm.a supplies _start, the allocator, read_input/write_output, exit,
 * _exit, abort and memcpy, so this only covers what newlib needs underneath
 * and what rv64im lacks.
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
 * `_heap_start` and `_heap_end` come from SP1's own zkvm.ld, which defines them
 * for the zkevm-standards `static-library-and-linker-script` standard. The
 * standard offers that range to the application's allocator, but SP1 does not
 * leave it free: before `main`, libzkevm.a's `_start` gives the same range,
 * `_end` up to the input region, to its own Rust allocator, and the
 * accelerators allocate from it.
 *
 * Two allocators on the same region overwrite each other's data, so newlib's
 * heap is reserved from SP1's allocator instead: half the range, on the first
 * call, which the Rust side then never gives out again. The other half stays
 * with libzkevm, far more than its accelerators use.
 *
 * Inside the reservation, a bump pointer is all newlib's malloc needs: it does
 * its own free-list management on top, so freed blocks are reused within the
 * region we hand out and the footprint tracks live memory rather than total
 * allocation.
 */

/* SP1's allocator, exported by libzkevm.a. SP1-specific, not in the standard. */
extern void *sys_alloc_aligned(size_t bytes, size_t align);

extern char _heap_start[];
extern char _heap_end[];

/* NULL until the first call reserves the heap. */
static char *heap_pos;
static char *heap_limit;

/* The `heap_end - _heap_start` below needs _heap_end's address in a register.
 * -mcmodel=medany computes it from the program counter:
 *
 *     auipc a0, %pcrel_hi(_heap_end)   a0 = pc + (20 bits << 12)
 *     addi  a0, a0, %pcrel_lo(...)     + 12 more bits
 *
 * a signed 32-bit offset from the instruction, so +-2 GiB. _heap_end is ~110
 * GiB from the code, which does not fit, and the link fails with "relocation
 * truncated to fit".
 *
 * The compiler can solve this itself with -mcmodel=large, which puts every
 * address in a constant pool next to the code and loads it from there,
 * including the ones that would fit, so each costs a memory load instead of
 * arithmetic. That is not usable here anyway: gcc puts those pools inside
 * .text, and a zkVM that transpiles the whole text segment up front then
 * decodes them as instructions. ZisK rejects such an ELF with:
 * "found invalid riscv_instruction.inst=c.fsd".
 *
 * Doing the same by hand, _heap_end becomes data, which has no range limit
 * (R_RISCV_64), and the code only has to reach the pointer.
 *
 *     auipc a0, %pcrel_hi(heap_end)    the pointer is in our own .data
 *     ld    a0, %pcrel_lo(...)(a0)     load the full 64-bit value from it
 *
 * volatile, or constant propagation replaces that load with the same computed
 * address and the relocation returns. Plain -O2 is enough for that, LTO or not,
 * and const does not help.
 *
 * _heap_start needs none of this: it is _end, just above the code. Only the
 * boundary symbol is far away, not the memory we use. */
static char *volatile heap_end = _heap_end;

void *_sbrk(ptrdiff_t incr) {
  if (heap_pos == NULL) {
    size_t size = (size_t)(heap_end - _heap_start) / 2;
    heap_pos = sys_alloc_aligned(size, 16);
    if (heap_pos == NULL) {
      errno = ENOMEM;
      return (void *)-1;
    }
    heap_limit = heap_pos + size;
  }

  /* -1, not NULL: that is sbrk's failure convention and what newlib checks. */
  if (incr > 0 && incr > heap_limit - heap_pos) {
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
 * libzkevm.a exports no printing function, but SP1's WRITE syscall is reachable
 * directly: `ecall` with t0=2, a0=fd, a1=buf, a2=len. Only fd 1 and 2 are
 * forwarded, the two the executor prints. The other descriptors are taken,
 * carrying the public values, the hint stream and host-side hooks.
 *
 * This is what makes a guest panic visible rather than surfacing as a wild
 * jump later.
 */

static void sp1_sys_write(uint32_t fd, const uint8_t *buf, size_t len) {
  register uint32_t t0 asm("t0") = 2; /* SyscallCode::WRITE */
  register uint32_t a0 asm("a0") = fd;
  register const uint8_t *a1 asm("a1") = buf;
  register size_t a2 asm("a2") = len;
  asm volatile("ecall" : : "r"(t0), "r"(a0), "r"(a1), "r"(a2) : "memory");
}

ssize_t _write(int fd, const void *buf, size_t count) {
  if ((fd == 1 || fd == 2) && count > 0)
    sp1_sys_write((uint32_t)fd, (const uint8_t *)buf, count);
  return (ssize_t)count;
}

/* --- atomics -------------------------------------------------------------
 *
 * SP1 is rv64im: integer and multiply/divide, no A extension. gcc therefore
 * lowers the std/atomics aristo uses into __atomic_* libcalls, which nothing in
 * the link provides. The guest is single-core and --threads:off, so there is
 * nothing to be atomic against and a plain read-modify-write is the correct
 * implementation rather than a shortcut.
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
 */

#include <pthread.h>

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a) {
  (void)m;
  (void)a;
  return 0;
}

int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_lock(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_unlock(pthread_mutex_t *m) { (void)m; return 0; }
