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
  eth/common/[headers, receipts],
  ../../../db/core_db

type
  BlockRef* = ref object
    header*  : Header
    txFrame* : CoreDbTxRef
    receipts*: seq[StoredReceipt]
    hash*    : Hash32
    parent*  : BlockRef

    index*   : uint
      # Alias to parent when serializing
      # Also used for DAG node finalized marker

template number*(b: BlockRef): BlockNumber =
  b.header.number

func `==`*(a, b: BlockRef): bool =
  if a.isNil.not and b.isNil.not:
    a.hash == b.hash
  else:
    false

template isOk*(b: BlockRef): bool =
  b.isNil.not

template loopItImpl(condition: untyped, init: BlockRef) =
  var it = init
  while it.condition:
    let next = it.parent
    yield it
    it = next 

template stateRoot*(b: BlockRef): Hash32 =
  b.header.stateRoot

const
  DAG_NODE_FINALIZED = 1

template finalize*(b: BlockRef) =
  b.index = DAG_NODE_FINALIZED

template notFinalized*(b: BlockRef): bool =
  b.index != DAG_NODE_FINALIZED

iterator ancestors*(init: BlockRef): BlockRef =
  loopItImpl(isOk, init)

iterator loopNotFinalized*(init: BlockRef): BlockRef =
  loopItImpl(notFinalized, init)

