# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  eth/common/base,
  eth/rlp,
  ../db/kvt/[kvt_desc, kvt_utils],
  ../db/storage_types

export base

# ------------------------------------------------------------------------------
# Public types
# ------------------------------------------------------------------------------

type
  PrunerState* = object
    active*: bool
      ## status of the last pruner operation, if it was activated or not
    tail*: BlockNumber
      ## old tail in the last node startup, should match with tail,
      ## else need to make it match by pruning the chain segment
    head*: BlockNumber
      ## old head of the last pruner operation before closing

# ------------------------------------------------------------------------------
# RLP serialization
# ------------------------------------------------------------------------------

proc append(w: var RlpWriter, s: PrunerState) =
  w.startList(3)
  w.append(s.active.byte)
  w.append(s.tail)
  w.append(s.head)

proc read(rlp: var Rlp, T: type PrunerState): T {.raises: [RlpError].} =
  rlp.tryEnterList()
  result.active = rlp.read(byte) != 0
  result.tail = BlockNumber(rlp.read(uint64))
  result.head = BlockNumber(rlp.read(uint64))

# ------------------------------------------------------------------------------
# Public save / load (KvtDbRef backend, no transaction layer)
# ------------------------------------------------------------------------------

proc savePrunerStateBe*(kvt: KvtDbRef, state: PrunerState) =
  let
    key = prunerStateKey()
    value = rlp.encode(state)
    batch = kvt.putBegFn().expect("pruner: savePrunerState putBegFn")
  kvt.putKvpFn(batch, key.toOpenArray, value)
  kvt.putEndFn(batch).expect("pruner: savePrunerState putEndFn")

proc loadPrunerStateBe*(kvt: KvtDbRef): PrunerState =
  let data = kvt.getBe(prunerStateKey().toOpenArray).valueOr:
    return PrunerState()
  try:
    return rlp.decode(data, PrunerState)
  except RlpError:
    discard
  PrunerState()
