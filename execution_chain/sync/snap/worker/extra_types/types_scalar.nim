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
  std/typetraits,
  pkg/eth/common,
  ../../../wire_protocol

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
# Public helpers
# ------------------------------------------------------------------------------

func `==`*(a, b: DistinctHash32): bool = a.distinctBase == b.distinctBase
func `!=`*(a, b: DistinctHash32): bool = a.distinctBase != b.distinctBase

template to*[T: Hash32](w: DistinctHash32; _: type T): T = T(w)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
