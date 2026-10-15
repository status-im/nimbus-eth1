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

type BodyData = object
  key: seq[byte]
  root: Hash32
  indexed: bool

func bodyData(header: Header): seq[BodyData] =
  # A seq rather than an iterator: an inline iterator with several `yield`s
  # would copy the caller's loop body once per `yield`
  for root in [header.txRoot, header.receiptsRoot]:
    if root != EMPTY_ROOT_HASH:
      result.add BodyData(key: @(hashIndexKey(root, 0)), root: root, indexed: true)
  if header.ommersHash != EMPTY_UNCLE_HASH:
    result.add BodyData(key: @(genericHashKey(header.ommersHash).toOpenArray))
  if header.withdrawalsRoot.isSome and header.withdrawalsRoot.get != EMPTY_ROOT_HASH:
    result.add BodyData(key: @(withdrawalsKey(header.withdrawalsRoot.get).toOpenArray))

proc readOwners(db: CoreDbTxRef, key: DbKey): seq[Hash32] =
  let stored = db.getOrEmpty(key.toOpenArray).expect("read block data owners")
  if stored.len != 0:
    try:
      return rlp.decode(stored, seq[Hash32])
    except RlpError:
      raiseAssert "Invalid block data owners"

proc writeBlockOwnershipData*(db: CoreDbTxRef, header: Header, hash: Hash32) =
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

proc releaseBlockOwnershipData(db: CoreDbTxRef, header: Header, hash: Hash32) =
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

proc writeCanonicalMappings*(c: ForkedChainRef, base: BlockRef) =
  ## Write the number and tx lookups of the blocks that become base, and make
  ## base the canonical head. On disk these cover the persisted chain only,
  ## which never reorgs, so they are never deleted. Blocks above base are
  ## looked up in memory.
  let db = c.baseTxFrame
  for b in ancestors(base):
    if b == c.base:
      break
    db.addBlockNumberToHashLookup(b.number, b.hash)
    for index, hash in b.txHashes:
      db.put(transactionHashToBlockKey(hash).toOpenArray,
        rlp.encode(TransactionKey(blockNumber: b.number, index: uint index))).
        expect("write transaction lookup")
  db.setHead(base.hash).expect("write canonical head")

proc deleteBlockData*(c: ForkedChainRef, b: BlockRef) =
  # Blocks above base have no number or tx lookups on disk to delete
  let db = c.baseTxFrame
  db.releaseBlockOwnershipData(b.header, b.hash)
  for key in [genericHashKey(b.hash), blockHashToScoreKey(b.hash),
              blockHashToBlockAccessListKey(b.hash), blockHashToWitnessKey(b.hash),
              txFrameKey(b.hash)]:
    db.del(key.toOpenArray).expect("delete dead block record")
