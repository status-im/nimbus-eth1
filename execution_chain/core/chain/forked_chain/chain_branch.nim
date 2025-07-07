# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common/blocks,
  eth/common/receipts,
  ../../../db/core_db

type
  BlockRef* = ref object
    blk*     : Block
    txFrame* : CoreDbTxRef
    receipts*: seq[StoredReceipt]
    hash*    : Hash32
    parent*  : BlockRef

    index*   : uint
      # Alias to parent when serializing
      # Also used for DAG node finalized marker

template header*(b: BlockRef): Header =
  b.blk.header

template number*(b: BlockRef): BlockNumber =
  b.blk.header.number

func `==`*(a, b: BlockRef): bool =
  a.hash == b.hash

template isOk*(b: BlockRef): bool =
  b.isNil.not

template loopIt*(init: BlockRef, body: untyped) =
  block:
    var it{.inject.} = init
    while it.isOk:
      body
      it = it.parent

template stateRoot*(b: BlockRef): Hash32 =
  b.blk.header.stateRoot

const
  DAG_NODE_FINALIZED = 1
  DAG_NODE_CLEAR = 0

template finalize*(b: BlockRef) =
  b.index = DAG_NODE_FINALIZED

template notFinalized*(b: BlockRef) =
  b.index = DAG_NODE_CLEAR

template finalized*(b: BlockRef): bool =
  b.index == DAG_NODE_FINALIZED

template loopFinalized*(init: BlockRef, body: untyped) =
  block:
    var it{.inject.} = init
    while not it.finalized:
      body
      it = it.parent

iterator everyNthBlock*(base: BlockRef, step: uint64): BlockRef =
  var
    number = base.number - min(base.number, step)
    steps  = newSeqOfCap[BlockRef](128)

  steps.add base

  loopIt(base):
    if it.number == number:
      steps.add it
      number -= min(number, step)

  for i in countdown(steps.len-1, 0):
    yield steps[i]
