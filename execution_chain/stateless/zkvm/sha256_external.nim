# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## nim-ssz-serialization's SHA-256 backend, hashing on the zkVM's accelerator.
##
## `ssz_serialization/digest` imports this module by name when built with
## `-d:PREFER_EXTERNAL_SHA256`, which the guest does. The module name and
## the exported symbols are its interface.

{.push raises: [], gcsafe.}

import ./zkvm_accelerators

func sha256*(input: openArray[byte], output: var array[32, byte]) =
  {.cast(noSideEffect).}:
    sha256Into(input, output)

func sha256*(a, b: openArray[byte], output: var array[32, byte]) =
  ## `digest` joins adjacent pairs and 64-byte pairs itself, without a copy, and
  ## every two-input call in nim-ssz today totals 64 bytes, so this branch is
  ## for completeness and the allocation is not on a hot path.
  var joined = newSeqUninit[byte](a.len + b.len)
  if a.len > 0:
    copyMem(addr joined[0], unsafeAddr a[0], a.len)
  if b.len > 0:
    copyMem(addr joined[a.len], unsafeAddr b[0], b.len)

  sha256(joined, output)
