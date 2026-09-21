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
  results,
  eth/common/headers,
  ../../../db/core_db

type
  BlockRef* = ref object
    header*  : Header
    txFrame* : CoreDbTxRef
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

func branchBlockHashFn*(parent: BlockRef): BlockHashFn =
  ## Resolve a block number against the branch that ends at `parent`.
  ##
  ## Blocks that have not been persisted yet are not in the database under
  ## their number - that mapping is canonical-only - so `BLOCKHASH` and
  ## friends would otherwise see the canonical chain while executing on a
  ## competing branch. Numbers below the base block are not on this branch
  ## either, but there all branches agree with the database, so `none` is the
  ## right answer there too.
  result = proc(n: BlockNumber): Opt[Hash32] {.gcsafe, raises: [].} =
    # A nil `txFrame` marks a block that has left the DAG, either persisted or
    # pruned; in both cases the database has the answer (or there is none).
    if parent.isNil or parent.txFrame.isNil or n > parent.number:
      return Opt.none(Hash32)
    for it in ancestors(parent):
      if it.txFrame.isNil:
        break
      if it.number == n:
        return Opt.some(it.hash)
      if it.number < n:
        break
    Opt.none(Hash32)
