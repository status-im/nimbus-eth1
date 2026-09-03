# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import std/[os, strutils], stew/ptrops

## zkVM guest I/O interface
##
## Spec: https://github.com/eth-act/zkevm-standards `standards/io-interface`
##
##   void read_input(const uint8_t** buf_ptr, size_t* buf_size);
##   void write_output(const uint8_t* output, size_t size);
##
## `read_input` hands out a read-only pointer into the preloaded private input.
## It cannot fail and is idempotent; at zero length the pointer is invalid.
## `write_output` appends to the public output, so successive calls concatenate.
##
## This module is only the binding: the link decides who implements the two
## symbols

# Location of the zkvm-standards' `zkvm_io.h`
const zkvmIoDir =
  currentSourcePath.rsplit({DirSep, AltSep}, 1)[0] &
  "/../../vendor/zkevm-standards/standards/io-interface"

# quoteShell is not defined when compiling to bare metal
when not defined(`any`) and not defined(standalone):
  {.passc: "-I" & quoteShell(zkvmIoDir).}
else:
  {.passc: "-I\"" & zkvmIoDir & "\"".}

# `buf_ptr` cannot be the matching `ptr ptr UncheckedArray[byte]`: the standard
# declares it `const uint8_t**`, and C does not accept a `uint8_t**` here. Nim
# cannot spell the const, and `void*` is the only pointer C converts freely, so
# `pointer` it is. Downside: no type check on `buf_ptr`.
#
# Getting this wrong is only an error on newer gcc and is silent on clang, which
# ignores the diagnostic in nimbase.h. Turn it into an error here instead, where
# it applies to this file alone.
{.emit: """/*TYPESECTION*/
#pragma GCC diagnostic error "-Wincompatible-pointer-types"
""".}
{.localPassC: "-Werror=incompatible-pointer-types".}

proc c_read_input(
  # Temp. fix disabled
  # buf_ptr: pointer, buf_size: ptr csize_t
  buf_ptr: ptr ptr UncheckedArray[byte], buf_size: ptr csize_t
) {.importc: "read_input", header: "zkvm_io.h".}

proc c_write_output(
  output: ptr byte, size: csize_t
) {.importc: "write_output", header: "zkvm_io.h".}

# Valid address to hand out when the input is empty. The standard leaves the
# pointer invalid at zero length:
# https://github.com/eth-act/zkevm-standards/blob/a87de83c494b1f02f7f8edd94a80e46233b46e82/standards/io-interface/README.md#L23
var emptyInputByte: byte

type ZkvmInput* = object
  ## Read-only view of the private input, valid for the whole program: the input
  ## is preloaded before `main` runs and is never released. Consume it with
  ## `toOpenArray`.
  data: ptr UncheckedArray[byte]
  size: int

template toOpenArray*(input: ZkvmInput): openArray[byte] =
  ## Borrow the input as an `openArray`, without copying.
  let borrowed = input
  borrowed.data.toOpenArray(0, borrowed.size - 1)

proc readInput*(): ZkvmInput =
  ## Borrow the private input, without copying.
  var
    buf: ptr UncheckedArray[byte]
    size: csize_t
  c_read_input(addr buf, addr size)
  if size == 0:
    # The standard leaves the pointer invalid here, so never propagate it.
    ZkvmInput(data: makeUncheckedArray(addr emptyInputByte), size: 0)
  else:
    ZkvmInput(data: buf, size: int(size))

proc writeOutput*(data: openArray[byte]) =
  ## Append to the public output. Successive calls concatenate.
  # Skip empty writes: there is nothing to append, and it avoids handing the
  # implementation a nil pointer, which is what `baseAddr` returns when empty.
  if data.len > 0:
    c_write_output(baseAddr(data), csize_t(data.len))
