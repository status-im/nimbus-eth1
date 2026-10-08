# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## nim-eth's keccak backend, hashing on the zkVM's accelerator.
##
## `eth/keccak/keccak` imports this module by name when built with
## `-d:keccakExternalBackend`, which the guest does. The module name and
## the exported symbols are its interface.

{.push raises: [], gcsafe.}

import ./zkvm_accelerators

type KeccakCtx* = object
  ## The accelerator has a one-shot form only, so the streaming context buffers
  ## and hashes once at `finish`. The buffer keeps its capacity across `clear`,
  ## so repeated users allocate once.
  buf: seq[byte]

func init*(h: var KeccakCtx) =
  h.buf.setLen(0)

template clear*(h: var KeccakCtx) =
  init(h)

func append(h: var KeccakCtx, data: openArray[byte]) =
  # `copyMem` reaches the zkVM's own accelerated memcpy.
  if data.len == 0:
    return

  let at = h.buf.len
  h.buf.setLenUninit(at + data.len)
  copyMem(addr h.buf[at], unsafeAddr data[0], data.len)

func update*(h: var KeccakCtx, data: openArray[byte]) =
  h.append(data)

func update*(h: var KeccakCtx, data: openArray[char]) =
  h.append(data.toOpenArrayByte(0, data.high))

func keccak256*(input: openArray[byte], output: var array[32, byte]) =
  {.cast(noSideEffect).}:
    keccak256Into(input, output)

func finish*(h: var KeccakCtx, output: var openArray[byte]) =
  doAssert output.len >= 32, "output must have room for the 32-byte digest"

  var digest {.noinit.}: array[32, byte]
  keccak256(h.buf, digest)
  copyMem(addr output[0], addr digest[0], 32)
