# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/atomics,
  unittest2,
  stew/endians2,
  results,
  eth/common/hashes,
  ../../execution_chain/db/aristo/[
    aristo_delete,
    aristo_desc,
    aristo_fetch,
    aristo_tx_frame,
    aristo_init/init_common,
    aristo_init/memory_only,
    aristo_merge,
  ]

proc makeAccount(i: uint64): (Hash32, AristoAccount) =
  var path: Hash32
  path.data()[0 .. 7] = i.toBytesBE()
  (path, AristoAccount(balance: i.u256, codeHash: EMPTY_CODE_HASH))

proc makeSlot(i: uint64): Hash32 =
  var path: Hash32
  path.data()[0 .. 7] = i.toBytesBE()
  path

proc makeSibling(i: uint64): Hash32 =
  ## A slot sharing every nibble of `makeSlot(i)` down past the depth at which
  ## that leaf currently sits, so that inserting it splits the leaf and moves it
  ## to a freshly allocated vid.
  result = makeSlot(i)
  result.data()[20] = 1

const
  acc1 = makeAccount(1)
  slotCount = 8'u64

proc reopen(db: AristoDbRef; stoLeavesSize, stoVidsSize: int) =
  ## Drop every in-memory frame and cache so that the next read has to go all
  ## the way to the backend. The persisted data survives.
  db.close()
  db.initInstance(
    accLeavesLruSize = 1024,
    stoLeavesLruSize = stoLeavesSize,
    stoLeafVidsLruSize = stoVidsSize).expect("working backend")

proc persist(db: AristoDbRef; tx: AristoTxRef; blockNumber: uint64) =
  tx.checkpoint(blockNumber, skipSnapshot = true)
  let batch = db.putBegFn().expect("working batch")
  db.persist(batch, tx)
  doAssert db.putEndFn(batch).isOk()

proc slotOf(db: AristoDbRef; slot: Hash32): UInt256 =
  db.baseTxFrame().fetchSlot(acc1[0], slot).expect("slot readable")

suite "Aristo storage leaf vid cache":
  setup:
    let db = AristoDbRef.init()

    block:
      let tx = db.txFrameBegin(db.baseTxFrame())
      doAssert tx.mergeAccount(acc1[0], acc1[1]).isOk()
      for i in 1'u64 .. slotCount:
        doAssert tx.mergeSlot(acc1[0], makeSlot(i), i.u256).isOk()
      db.persist(tx, 1'u64)

    # A single-entry payload cache means every read demotes the previous slot's
    # vid into the second-level cache, which is what we want to exercise.
    db.reopen(stoLeavesSize = 1, stoVidsSize = 1024)

  test "a demoted vid turns the descent into a single verified lookup":
    for i in 1'u64 .. slotCount:
      check db.slotOf(makeSlot(i)) == i.u256

    check db.stoVidMisses.load(moRelaxed) > 0

    let
      hitsBefore = db.stoVidHits.load(moRelaxed)
      staleBefore = db.stoVidStale.load(moRelaxed)

    # Second pass: every slot bar the one still resident in the payload cache
    # was demoted, so these are served from the vid cache.
    for i in 1'u64 .. slotCount:
      check db.slotOf(makeSlot(i)) == i.u256

    check:
      db.stoVidHits.load(moRelaxed) > hitsBefore
      db.stoVidStale.load(moRelaxed) == staleBefore

  test "a vid left stale by a leaf split is rejected, not trusted":
    for i in 1'u64 .. slotCount:
      check db.slotOf(makeSlot(i)) == i.u256

    # Splitting each leaf moves it to a new vid, leaving every cached vid
    # pointing at what is now a branch.
    block:
      let tx = db.txFrameBegin(db.baseTxFrame())
      for i in 1'u64 .. slotCount:
        doAssert tx.mergeSlot(acc1[0], makeSibling(i), (i + 100).u256).isOk()
      db.persist(tx, 2'u64)

    let staleBefore = db.stoVidStale.load(moRelaxed)

    # The vid cache still points at where the leaves used to live. Every read
    # must still return the right value.
    for i in 1'u64 .. slotCount:
      check db.slotOf(makeSlot(i)) == i.u256
      check db.slotOf(makeSibling(i)) == (i + 100).u256

    check db.stoVidStale.load(moRelaxed) > staleBefore

  test "a deleted slot reads as zero rather than resurrecting a stale vid":
    for i in 1'u64 .. slotCount:
      check db.slotOf(makeSlot(i)) == i.u256

    block:
      let tx = db.txFrameBegin(db.baseTxFrame())
      for i in 1'u64 .. slotCount:
        doAssert tx.deleteSlot(acc1[0], makeSlot(i)).isOk()
      db.persist(tx, 2'u64)

    for i in 1'u64 .. slotCount:
      check db.slotOf(makeSlot(i)) == 0.u256

  test "wiping the account invalidates the whole storage vid cache at once":
    for i in 1'u64 .. slotCount:
      check db.slotOf(makeSlot(i)) == i.u256

    # `delStoTreeNow` walks the storage trie and tombstones every slot it finds,
    # so this is the bulk-staleness case the `persist` invalidation covers.
    block:
      let tx = db.txFrameBegin(db.baseTxFrame())
      doAssert tx.deleteAccount(acc1[0]).isOk()
      db.persist(tx, 2'u64)

    for i in 1'u64 .. slotCount:
      check db.baseTxFrame().fetchSlot(acc1[0], makeSlot(i)) ==
        Result[UInt256, AristoError].err(FetchPathNotFound)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
