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
  pkg/eth/common

type
  StateRoot* = distinct Hash32
  BlockHash* = distinct Hash32
  StoreRoot* = distinct Hash32
  CodeHash* = distinct Hash32

  DistinctHash32* = StateRoot | BlockHash | StoreRoot | CodeHash
    ## For generic function arguments

func hash*(a: DistinctHash32): Hash =
  ## Mixin for table or minilru drivers
  hashes.hash(a.distinctBase)

func `==`*(a, b: DistinctHash32): bool = a.distinctBase == b.distinctBase
func `!=`*(a, b: DistinctHash32): bool = a.distinctBase != b.distinctBase

func toStr*(w: DistinctHash32): string = w.Hash32.short

template to*(w: Hash32, _: type StateRoot): StateRoot = StateRoot(w)
template to*(w: Hash32, _: type BlockHash): BlockHash = BlockHash(w)
template to*(w: Hash32, _: type StoreRoot): StoreRoot = StoreRoot(w)
template to*(w: Hash32, _: type CodeHash): CodeHash = CodeHash(w)

# End
