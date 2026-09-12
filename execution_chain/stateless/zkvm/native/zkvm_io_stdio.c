/**
 * Nimbus
 * Copyright (c) 2026 Status Research & Development GmbH
 * Licensed under either of
 *   * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
 *   * MIT license ([LICENSE-MIT](LICENSE-MIT))
 * at your option.
 * This file may not be copied, modified, or distributed except according to
 * those terms.
 */

/**
 * stdio-backed implementation of the zkVM IO interface.
 *
 * This is a stand-in for the vendor-supplied static library described by
 * zkvm-standards `standards/static-library-and-linker-script`: it provides the
 * same two symbols, with the same semantics, backed by stdin/stdout instead of
 * a zkVM. The `stateless_guest_native` make target links the guest against this
 * so it can be driven as an ordinary binary over a pipe.
 *
 * Because the Nim side binds these symbols identically either way, the pipe
 * test exercises the real FFI path rather than a parallel native code path.
 *
 * Semantics preserved from the standard:
 *  - read_input is idempotent, and zero-copy: the whole input is slurped once
 *    into an internal buffer and the same pointer is handed out every time.
 *  - write_output appends: successive calls concatenate.
 *  - Neither can fail, and neither can report an error. A real zkVM has the
 *    input in memory and cannot hit the paths below, so rather than pass the
 *    guest a short or empty buffer, this dies on stderr.
 */

#include "zkvm_io.h"

#include <stdio.h>
#include <stdlib.h>

static uint8_t *g_input;
static size_t g_input_size;
static int g_input_loaded;

static void die(const char *what) {
    fprintf(stderr, "zkvm_io_stdio: %s\n", what);
    exit(EXIT_FAILURE);
}

/* Read all of stdin into g_input. Called once, on the first read_input. */
static void load_input(void) {
    size_t cap = 1 << 16; /* one allocation for all but ~0.4% of EEST inputs */
    size_t len = 0;
    size_t n;
    uint8_t *buf;

    if (g_input_loaded) {
        return;
    }
    g_input_loaded = 1;

    buf = malloc(cap);
    if (buf == NULL) {
        die("out of memory reading stdin");
    }

    for (;;) {
        if (len == cap) {
            /* cap * 2 should not overflow: realloc fails well before SIZE_MAX/2 */
            uint8_t *grown = realloc(buf, cap * 2);
            if (grown == NULL) {
                die("out of memory reading stdin");
            }
            buf = grown;
            cap *= 2;
        }
        n = fread(buf + len, 1, cap - len, stdin);
        len += n;
        if (n == 0) {
            /* cap - len was nonzero, so 0 bytes means EOF or a read error */
            if (ferror(stdin)) {
                die("error reading stdin");
            }
            break;
        }
    }

    g_input = buf;
    g_input_size = len;
}

void read_input(const uint8_t **buf_ptr, size_t *buf_size) {
    load_input();
    *buf_ptr = g_input;
    *buf_size = g_input_size;
}

void write_output(const uint8_t *output, size_t size) {
    if (size > 0 && fwrite(output, 1, size, stdout) != size) {
        die("error writing stdout");
    }
    if (fflush(stdout) != 0) {
        die("error flushing stdout");
    }
}
