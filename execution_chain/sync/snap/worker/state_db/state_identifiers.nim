# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[hashes, typetraits],
  ../../../wire_protocol,
  pkg/eth/common

type
  StateRoot* = distinct Hash32
  BlockHash* = distinct Hash32
  StoreRoot* = distinct Hash32
  CodeHash* = distinct Hash32

  DistinctHash32* = StateRoot | BlockHash | StoreRoot | CodeHash
    ## For generic function arguments

  DistinctSeqHash32* = seq[StoreRoot] | seq[CodeHash]
    ## For generic function arguments

# ------------------------------------------------------------------------------
# Public `Rlp` and `Table` helpers
# ------------------------------------------------------------------------------

func hash*(a: DistinctHash32): Hash =
  ## Mixin for table or minilru drivers
  hashes.hash(a.distinctBase)

proc read*[T: DistinctHash32](
    r: var Rlp; _: type T): T {.gcsafe, raises: [RlpError]} =
  ## RLP mixin, decoding
  r.read(Hash32).T

proc append*[T: DistinctHash32](w: var RlpWriter, val: T) =
  w.append Hash32(val)

func `==`*(a, b: DistinctHash32): bool = a.distinctBase == b.distinctBase
func `!=`*(a, b: DistinctHash32): bool = a.distinctBase != b.distinctBase

# ------------------------------------------------------------------------------
# Public type mappers
# ------------------------------------------------------------------------------

template to*[T: DistinctHash32](w: Hash32, _: type T): T = T(w)

template to*[T: Hash32](w: DistinctHash32; _: type T): T = T(w)

template to*[T: seq[Hash32]](w: DistinctSeqHash32, _: type T): T = cast[T](w)

template to*[T: StoreRoot](w: SnapRootHash, _: type T): T = T(w.Hash32)

template to*[T: CodeHash](w: SnapCodeHash, _: type T): T = T(w.Hash32)

# ------------------------------------------------------------------------------
# Public print function()s
# ------------------------------------------------------------------------------

func toStr*(w: DistinctHash32): string = w.Hash32.short

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
