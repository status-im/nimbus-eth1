# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common/headers,
  ../../../db/core_db

type
  BlockRef* = ref object
    header*  : Header
    txFrame* : CoreDbTxRef
    hash*    : Hash32
    parent*  : BlockRef

    txHashes*: seq[Hash32]
      # In block order. The tx lookup on disk covers base and below only,
      # this is the lookup for blocks above base.

    isFinalized*: bool

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

template finalize*(b: BlockRef) =
  b.isFinalized = true

template notFinalized*(b: BlockRef): bool =
  not b.isFinalized

proc branchBlockHashFn*(parent: BlockRef, number: BlockNumber, hash: Hash32): BlockHashFn =
  ## Block hashes of the branch made of block (`number`, `hash`) on top of
  ## `parent`. Numbers below the in-memory part of the branch resolve from the
  ## canonical index on disk. Captures the parent rather than the block, so the
  ## block's frame holding the closure does not form a cycle with the block.
  proc(n: BlockNumber): Opt[Hash32] =
    if n == number:
      return Opt.some(hash)
    var it = parent
    while not it.isNil and not it.txFrame.isNil and n <= it.number:
      if n == it.number:
        return Opt.some(it.hash)
      it = it.parent
    Opt.none(Hash32)

iterator ancestors*(init: BlockRef): BlockRef =
  loopItImpl(isOk, init)

iterator loopNotFinalized*(init: BlockRef): BlockRef =
  loopItImpl(notFinalized, init)
