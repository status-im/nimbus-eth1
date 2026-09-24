# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  ../../../db/[core_db, storage_types, tx_frame_db],
  ../../../db/kvt/[kvt_desc, kvt_utils],
  ../../../common,
  ./chain_branch,
  ./chain_desc

proc invalidateFcSnapshot*(db: CoreDbTxRef, force = false): CoreDbRc[void] =
  # Indexed DAG entries are valid only as a complete snapshot. Once the
  # shared database changes, a restart must not load the old manifest.
  if force or db.hasKey(fcStateKey(0).toOpenArray):
    db.kvt.delRangeBe([byte(ord(DBKeyKind.fcState))],
                     [byte(ord(DBKeyKind.fcState) + 1)]).isOkOr:
      return err(error.toError("invalidate FC snapshot"))
  ok()

type BodyData = object
  key: seq[byte]
  root: Hash32
  indexed: bool

iterator bodyData(header: Header): BodyData =
  for root in [header.txRoot, header.receiptsRoot]:
    if root != EMPTY_ROOT_HASH:
      yield BodyData(key: @(hashIndexKey(root, 0)), root: root, indexed: true)
  if header.ommersHash != EMPTY_UNCLE_HASH:
    yield BodyData(key: @(genericHashKey(header.ommersHash).toOpenArray))
  if header.withdrawalsRoot.isSome and header.withdrawalsRoot.get != EMPTY_ROOT_HASH:
    yield BodyData(key: @(withdrawalsKey(header.withdrawalsRoot.get).toOpenArray))

proc readOwners(db: CoreDbTxRef, key: DbKey): seq[Hash32] =
  let stored = db.getOrEmpty(key.toOpenArray).expect("read block data owners")
  if stored.len != 0:
    try:
      return rlp.decode(stored, seq[Hash32])
    except RlpError:
      raiseAssert "Invalid block data owners"

proc retainBlockData*(db: CoreDbTxRef, header: Header, hash: Hash32) =
  # Register before writing the payload, idempotently even after a partial
  # import. Content already present without owners belongs to finalized
  # history (or an older database) and must survive deletion of a new fork.
  for data in bodyData(header):
    let key = blockDataRefsKey(keccak256(data.key))
    var owners = db.readOwners(key)
    if owners.len == 0 and db.hasKey(data.key):
      continue
    if hash notin owners:
      owners.add hash
      db.put(key.toOpenArray, rlp.encode(owners)).expect("retain block data")

proc finalizeBlockData*(db: CoreDbTxRef, header: Header) =
  # Once canonical history owns a payload, ordinary history pruning is
  # responsible for its lifetime, even if live forks also reference it.
  for data in bodyData(header):
    db.del(blockDataRefsKey(keccak256(data.key)).toOpenArray).
      expect("finalize block data")

proc releaseBlockData(db: CoreDbTxRef, header: Header, hash: Hash32) =
  for data in bodyData(header):
    let key = blockDataRefsKey(keccak256(data.key))
    var owners = db.readOwners(key)
    let index = owners.find(hash)
    if index < 0:
      continue # finalized, pre-existing, or already released
    owners.del(index)
    if owners.len > 0:
      db.put(key.toOpenArray, rlp.encode(owners)).expect("release block data")
    else:
      # Drop ownership first: interruption can leave unused content behind,
      # but never a stale owner that could later delete another block's data.
      db.del(key.toOpenArray).expect("delete block data owners")
      if data.indexed:
        db.kvt.delRangeBe(hashIndexKey(data.root, 0),
          hashIndexKey(data.root, uint16.high)).expect("delete block payload")
        db.del(hashIndexKey(data.root, uint16.high)).expect("delete last payload entry")
      else:
        db.del(data.key).expect("delete block payload")

proc writeTransactionMappings*(c: ForkedChainRef, b: BlockRef) =
  let db = c.baseTxFrame
  var index = 0'u
  for encodedTx in db.getBlockTransactionData(b.header.txRoot):
    let hash = keccak256(encodedTx)
    db.put(transactionHashToBlockKey(hash).toOpenArray,
      rlp.encode(TransactionKey(blockNumber: b.number, index: index))).
      expect("restore transaction lookup")
    if b.number > c.base.number:
      c.txRecords[hash] = (b.hash, uint64(index))
    inc index

proc writeCanonicalMappings*(c: ForkedChainRef, head: BlockRef) =
  # Frame switching no longer switches KVT indexes. Explicitly restore the
  # chosen branch's number and transaction lookups, including the base.
  for b in ancestors(head):
    c.baseTxFrame.addBlockNumberToHashLookup(b.number, b.hash)
    c.writeTransactionMappings(b)

proc deleteBlockData*(c: ForkedChainRef, b: BlockRef) =
  let db = c.baseTxFrame
  # Delete transaction lookups only if they still name the discarded
  # location and the selected block doesn't contain that same transaction.
  var index = 0'u
  for encodedTx in db.getBlockTransactionData(b.header.txRoot):
    let
      hash = keccak256(encodedTx)
      location = db.getTransactionKey(hash).expect("read transaction lookup")
    if location.blockNumber == b.number and location.index == index:
      var keep = false
      c.txRecords.withValue(hash, owner):
        keep = owner[][0] != b.hash
      let canonical = db.getBlockHeader(b.number)
      if not keep and canonical.isOk and canonical.value.computeBlockHash != b.hash:
        let tx = db.getTransactionByIndex(canonical.value.txRoot, index.uint16)
        keep = tx.isOk and tx.value.computeRlpHash == hash
      if not keep:
        db.del(transactionHashToBlockKey(hash).toOpenArray).
          expect("delete transaction lookup")
    inc index

  db.releaseBlockData(b.header, b.hash)
  for key in [genericHashKey(b.hash), blockHashToScoreKey(b.hash),
              blockHashToBlockAccessListKey(b.hash), blockHashToWitnessKey(b.hash),
              txFrameKey(b.hash)]:
    db.del(key.toOpenArray).expect("delete dead block record")

  if db.getBlockHash(b.number).valueOr(zeroHash32) == b.hash:
    db.del(blockNumberToHashKey(b.number).toOpenArray).expect("delete block lookup")
    when compileOption("threads"):
      db.kvt.blockHashes.del(b.number)
