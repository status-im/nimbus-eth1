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
  unittest2,
  results,
  eth/common/hashes,
  ../../execution_chain/db/aristo/[
    aristo_delete,
    aristo_desc,
    aristo_fetch,
    aristo_get,
    aristo_merge,
    aristo_tx_frame,
    aristo_vid,
    aristo_init/init_common,
    aristo_init/memory_only,
  ]

proc pathWith(prefix: byte, tail: byte): Hash32 =
  ## Paths sharing the first 12 nibbles (6 bytes) when `prefix` matches
  var path: Hash32
  for i in 0 ..< 6:
    path.data[i] = prefix
  path.data[6] = tail
  path.data[31] = tail
  path

proc account(i: uint64): AristoAccount =
  AristoAccount(balance: i.u256, codeHash: EMPTY_CODE_HASH)

const
  pA = pathWith(0x11, 0x01)
  pB = pathWith(0x11, 0x02)
  pC = pathWith(0x22, 0x03)
  pMissingShared = pathWith(0x11, 0x04)
  pMissingOther = pathWith(0x33, 0x05)
  slot1 = pathWith(0x44, 0x01)
  slot2 = pathWith(0x44, 0x02)

proc build(paths: openArray[(Hash32, AristoAccount)]): AristoDbRef =
  result = AristoDbRef.init()
  let tx = result.txFrameBegin(result.baseTxFrame())
  for (path, acc) in paths:
    doAssert tx.mergeAccount(path, acc).isOk()
  tx.checkpoint(1, skipSnapshot = true)
  let batch = result.putBegFn().expect("batch")
  result.persist(batch, tx)
  doAssert result.putEndFn(batch).isOk()

suite "Aristo derived leaf vids":
  test "Leaves sharing the derived vid escape to allocated vids":
    check derivedVid(pA) == derivedVid(pB)
    check derivedVid(pA) != derivedVid(pC)
    check derivedVid(pA).isDerived()

    let db = AristoDbRef.init()
    let tx = db.txFrameBegin(db.baseTxFrame())

    check:
      tx.mergeAccount(pA, account(1)).isOk()
      tx.mergeAccount(pC, account(3)).isOk()
      tx.getVtxRc((STATE_ROOT_VID, derivedVid(pA))).value()[0].vType == AccLeaf
      tx.mergeAccount(pB, account(2)).isOk()

    let marker = tx.getVtxRc((STATE_ROOT_VID, derivedVid(pA))).value()[0]
    check:
      marker.vType == LeafPtr
      LeafPtrRef(marker).vid == VertexID(0)

      tx.fetchAccount(pA).value() == account(1)
      tx.fetchAccount(pB).value() == account(2)
      tx.fetchAccount(pC).value() == account(3)
      tx.fetchAccount(pMissingShared).error() == FetchPathNotFound
      tx.fetchAccount(pMissingOther).error() == FetchPathNotFound

    var hike: Hike
    check:
      tx.fetchAccountHike(pA, hike).isOk()
      not hike.legs[^1].wp.vid.isDerived()
      tx.fetchAccountHike(pC, hike).isOk()
      hike.legs[^1].wp.vid.isDerived()

    # Insertion order does not change the trie hash
    let reference = build([(pB, account(2)), (pC, account(3)), (pA, account(1))])
    check tx.fetchStateRoot() == reference.baseTxFrame().fetchStateRoot()

    # Collapse back through the escaped leaf
    check:
      tx.deleteAccount(pB).isOk()
      tx.fetchAccount(pA).value() == account(1)
      tx.fetchAccount(pB).error() == FetchPathNotFound
      tx.fetchStateRoot() ==
        build([(pA, account(1)), (pC, account(3))]).baseTxFrame().fetchStateRoot()

      tx.deleteAccount(pC).isOk()
      tx.getVtxRc((STATE_ROOT_VID, STATE_ROOT_VID)).value()[0].vType == LeafPtr
      tx.fetchAccount(pA).value() == account(1)
      tx.fetchStateRoot() == build([(pA, account(1))]).baseTxFrame().fetchStateRoot()

    # Reload from the backend with direct fetch on, the marker forces the walk
    tx.checkpoint(1, skipSnapshot = true)
    let batch = db.putBegFn().expect("batch")
    db.persist(batch, tx)
    check db.putEndFn(batch).isOk()
    db.close()
    db.initInstance().expect("reload")
    check:
      db.directLeafFetch
      db.baseTxFrame().fetchAccount(pA).value() == account(1)
      db.baseTxFrame().fetchAccount(pB).error() == FetchPathNotFound
      db.baseTxFrame().fetchAccount(pMissingShared).error() == FetchPathNotFound

  test "Storage slots sharing the derived vid":
    let db = AristoDbRef.init()
    let tx = db.txFrameBegin(db.baseTxFrame())

    check:
      tx.mergeAccount(pC, account(3)).isOk()
      tx.mergeSlot(pC, slot1, 11.u256).isOk()
      tx.mergeSlot(pC, slot2, 22.u256).isOk()
      tx.fetchSlot(pC, slot1).value() == 11.u256
      tx.fetchSlot(pC, slot2).value() == 22.u256
      tx.fetchSlot(pC, pathWith(0x44, 0x03)).value() == 0.u256

    let stoID = tx.fetchStorageID(pC).value()
    check:
      stoID.isValid()
      tx.getVtxRc((stoID, derivedVid(slot1))).value()[0].vType == LeafPtr

      tx.deleteSlot(pC, slot1).isOk()
      tx.fetchSlot(pC, slot1).value() == 0.u256
      tx.fetchSlot(pC, slot2).value() == 22.u256
      tx.getVtxRc((stoID, stoID)).value()[0].vType == LeafPtr

      tx.deleteSlot(pC, slot2).isOk()
      tx.fetchSlot(pC, slot2).value() == 0.u256
      not tx.fetchStorageID(pC).value().isValid()
