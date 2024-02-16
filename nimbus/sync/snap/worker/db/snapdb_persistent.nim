# nimbus-eth1
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, tables],
  chronicles,
  eth/[common, trie/db],
  results,
  ../../../../db/[core_db, kvstore_rocksdb],
  ../../range_desc,
  "."/[hexary_desc, hexary_error, rocky_bulk_load, snapdb_desc]

logScope:
  topics = "snap-db"

type
  AccountsGetFn* = proc(key: openArray[byte]): Blob
    {.gcsafe, raises:[].}
      ## The `get()` function for the accounts trie

  ContractsGetFn* = proc(key: openArray[byte]): Blob
    {.gcsafe, raises:[].}
      ## The `get()` function for the contracts table

  StorageSlotsGetFn* = proc(acc: NodeKey; key: openArray[byte]): Blob
    {.gcsafe, raises: [].}
      ## The `get()` function for the storage tries depends on the current
      ## account

  StateRootRegistry* = object
    ## State root record. A table of these kind of records is organised as
    ## follows.
    ## ::
    ##    zero -> (n/a) -------+
    ##                         |
    ##             ...         |
    ##              ^          |
    ##              |          |
    ##            (data)       |
    ##              ^          |
    ##              |          |
    ##            (data)       |
    ##              ^          |
    ##              |          |
    ##            (data) <-----+
    ##
    key*: NodeKey  ## Top reference for base entry, back reference otherwise
    data*: Blob    ## Some data

const
  extraTraceMessages = false # or true
    ## Enable additional logging noise

# ------------------------------------------------------------------------------
# Private helpers, logging
# ------------------------------------------------------------------------------

when false:
  template logTxt(info: static[string]): static[string] =
    "Persistent db " & info

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc convertTo(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use
  discard result.init(key.ByteArray33[1 .. 32])

proc convertTo(key: RepairKey; T: type NodeTag): T =
  ## Might be lossy, check before use
  UInt256.fromBytesBE(key.ByteArray33[1 .. 32]).T

proc toAccountsKey(a: RepairKey): auto =
  a.convertTo(NodeKey).toAccountsKey

proc toStorageSlotsKey(a: RepairKey): auto =
  a.convertTo(NodeKey).toStorageSlotsKey

proc stateRootGet*(db: CoreDbRef; nodeKey: Nodekey): Blob =
  if db.isLegacy:
    return db.kvt.backend.toLegacy.get(nodeKey.toStateRootKey.toOpenArray)

# ------------------------------------------------------------------------------
# Public functions: get
# ------------------------------------------------------------------------------

proc persistentAccountsGetFn*(db: CoreDbRef): AccountsGetFn =
  ## Returns a `get()` function for retrieving accounts data
  return proc(key: openArray[byte]): Blob =
    var nodeKey: NodeKey
    if nodeKey.init(key):
      if db.isLegacy:
        return db.kvt.backend.toLegacy.get(
          nodeKey.toAccountsKey.toOpenArray)

proc persistentContractsGetFn*(db: CoreDbRef): ContractsGetFn =
  ## Returns a `get()` function for retrieving contracts data
  return proc(key: openArray[byte]): Blob =
    var nodeKey: NodeKey
    if nodeKey.init(key):
      if db.isLegacy:
        return db.kvt.backend.toLegacy.get(
          nodeKey.toContractHashKey.toOpenArray)

proc persistentStorageSlotsGetFn*(db: CoreDbRef): StorageSlotsGetFn =
  ## Returns a `get()` function for retrieving storage slots data
  return proc(accKey: NodeKey; key: openArray[byte]): Blob =
    var nodeKey: NodeKey
    if nodeKey.init(key):
      if db.isLegacy:
        return db.kvt.backend.toLegacy.get(
          nodeKey.toStorageSlotsKey.toOpenArray)

proc persistentStateRootGet*(
    db: CoreDbRef;
    root: NodeKey;
      ): Result[StateRootRegistry,HexaryError] =
  ## Implements a `get()` function for returning state root registry data.
  let rlpBlob = db.stateRootGet(root)
  if 0 < rlpBlob.len:
    try:
      return ok(rlp.decode(rlpBlob, StateRootRegistry))
    except RlpError:
      return err(RlpEncoding)
  err(StateRootNotFound)

# ------------------------------------------------------------------------------
# Public functions: store/put
# ------------------------------------------------------------------------------

proc persistentBlockHeaderPut*(
    db: CoreDbRef;
    hdr: BlockHeader;
      ) =
  ## Store a single header. This function is intended to finalise snap sync
  ## with storing a universal pivot header not unlike genesis.
  let hashKey = hdr.blockHash
  db.kvt.put(hashKey.toBlockHeaderKey.toOpenArray, rlp.encode(hdr))
  db.kvt.put(hdr.blockNumber.toBlockNumberKey.toOpenArray, rlp.encode(hashKey))
  when extraTraceMessages:
    trace logTxt "stored block header", hashKey,
      blockNumber=hdr.blockNumber.toStr,
      dbVerify=(0 < db.get(hashKey.toBlockHeaderKey.toOpenArray).len)

proc persistentAccountsPut*(
    db: HexaryTreeDbRef;
    base: CoreDbRef;
      ): Result[void,HexaryError] =
  ## Bulk store using transactional `put()`
  let dbTx = base.beginTransaction
  defer: dbTx.commit

  for (key,value) in db.tab.pairs:
    if not key.isNodeKey:
      let error = UnresolvedRepairNode
      when extraTraceMessages:
        trace logTxt "unresolved node in repair table", error
      return err(error)
    base.kvt.put(key.toAccountsKey.toOpenArray, value.convertTo(Blob))
  ok()

proc persistentStorageSlotsPut*(
    db: HexaryTreeDbRef;
    base: CoreDbRef;
      ): Result[void,HexaryError] =
  ## Bulk store using transactional `put()`
  let dbTx = base.beginTransaction
  defer: dbTx.commit

  for (key,value) in db.tab.pairs:
    if not key.isNodeKey:
      let error = UnresolvedRepairNode
      when extraTraceMessages:
        trace logTxt "unresolved node in repair table", error
      return err(error)
    base.kvt.put(key.toStorageSlotsKey.toOpenArray, value.convertTo(Blob))
  ok()

proc persistentContractPut*(
    data: seq[(NodeKey,Blob)];
    base: CoreDbRef;
      ): Result[void,HexaryError]
      {.gcsafe, raises: [].} =
  ## SST based bulk load on `rocksdb`.
  let dbTx = base.beginTransaction
  defer: dbTx.commit

  for (key,val) in data:
    base.kvt.put(key.toContracthashKey.toOpenArray,val)
  ok()


proc persistentStateRootPut*(
    db: CoreDbRef;
    root: NodeKey;
    data: Blob;
      ) {.gcsafe, raises: [RlpError].} =
  ## Save or update state root registry data.
  const
    zeroKey = NodeKey.default
  let
    rlpData = db.stateRootGet(root)

  if rlpData.len == 0:
    var backKey: NodeKey

    let baseBlob = db.stateRootGet(zeroKey)
    if 0 < baseBlob.len:
      backKey = rlp.decode(baseBlob, StateRootRegistry).key

    # No need for a transaction frame. If the system crashes in between,
    # so be it :). All that can happen is storing redundant top entries.
    let
      rootEntryData = rlp.encode StateRootRegistry(key: backKey, data: data)
      zeroEntryData = rlp.encode StateRootRegistry(key: root)

    # Store a new top entry
    db.kvt.put(root.toStateRootKey.toOpenArray, rootEntryData)

    # Store updated base record pointing to top entry
    db.kvt.put(zeroKey.toStateRootKey.toOpenArray, zeroEntryData)

  else:
    let record = rlp.decode(rlpData, StateRootRegistry)
    if record.data != data:

      let rootEntryData =
        rlp.encode StateRootRegistry(key: record.key, data: data)

      db.kvt.put(root.toStateRootKey.toOpenArray, rootEntryData)


proc persistentAccountsPut*(
    db: HexaryTreeDbRef;
    rocky: RocksStoreRef
      ): Result[void,HexaryError]
      {.gcsafe, raises: [OSError,IOError,KeyError].} =
  ## SST based bulk load on `rocksdb`.
  if rocky.isNil:
    return err(NoRocksDbBackend)
  let bulker = RockyBulkLoadRef.init(rocky)
  defer: bulker.destroy()
  if not bulker.begin(RockyBulkCache):
    let error = CannotOpenRocksDbBulkSession
    when extraTraceMessages:
      trace logTxt "rocksdb session initiation failed",
        error, info=bulker.lastError()
    return err(error)

  #let keyList = toSeq(db.tab.keys)
  #              .filterIt(it.isNodeKey)
  #              .mapIt(it.convertTo(NodeTag))
  #              .sorted(cmp)
  var
    keyList = newSeq[NodeTag](db.tab.len)
    inx = 0
  for repairKey in db.tab.keys:
    if repairKey.isNodeKey:
      keyList[inx] = repairKey.convertTo(NodeTag)
      inx.inc
  if inx < db.tab.len:
    return err(UnresolvedRepairNode)
  keyList.sort(cmp)

  for n,nodeTag in keyList:
    let
      nodeKey = nodeTag.to(NodeKey)
      data = db.tab[nodeKey.to(RepairKey)].convertTo(Blob)
    if not bulker.add(nodeKey.toAccountsKey.toOpenArray, data):
      let error = AddBulkItemFailed
      when extraTraceMessages:
        trace logTxt "rocksdb bulk stash failure",
          n, len=db.tab.len, error, info=bulker.lastError()
      return err(error)

  if bulker.finish().isErr:
    let error = CommitBulkItemsFailed
    when extraTraceMessages:
      trace logTxt "rocksdb commit failure",
        len=db.tab.len, error, info=bulker.lastError()
    return err(error)
  ok()


proc persistentStorageSlotsPut*(
    db: HexaryTreeDbRef;
    rocky: RocksStoreRef
      ): Result[void,HexaryError]
      {.gcsafe, raises: [OSError,IOError,KeyError].} =
  ## SST based bulk load on `rocksdb`.
  if rocky.isNil:
    return err(NoRocksDbBackend)
  let bulker = RockyBulkLoadRef.init(rocky)
  defer: bulker.destroy()
  if not bulker.begin(RockyBulkCache):
    let error = CannotOpenRocksDbBulkSession
    when extraTraceMessages:
      trace logTxt "rocksdb session initiation failed",
        error, info=bulker.lastError()
    return err(error)

  #let keyList = toSeq(db.tab.keys)
  #              .filterIt(it.isNodeKey)
  #              .mapIt(it.convertTo(NodeTag))
  #              .sorted(cmp)
  var
    keyList = newSeq[NodeTag](db.tab.len)
    inx = 0
  for repairKey in db.tab.keys:
    if repairKey.isNodeKey:
      keyList[inx] = repairKey.convertTo(NodeTag)
      inx.inc
  if inx < db.tab.len:
    return err(UnresolvedRepairNode)
  keyList.sort(cmp)

  for n,nodeTag in keyList:
    let
      nodeKey = nodeTag.to(NodeKey)
      data = db.tab[nodeKey.to(RepairKey)].convertTo(Blob)
    if not bulker.add(nodeKey.toStorageSlotsKey.toOpenArray, data):
      let error = AddBulkItemFailed
      when extraTraceMessages:
        trace logTxt "rocksdb bulk stash failure",
          n, len=db.tab.len, error, info=bulker.lastError()
      return err(error)

  if bulker.finish().isErr:
    let error = CommitBulkItemsFailed
    when extraTraceMessages:
      trace logTxt "rocksdb commit failure",
        len=db.tab.len, error, info=bulker.lastError()
    return err(error)
  ok()


proc persistentContractPut*(
    data: seq[(NodeKey,Blob)];
    rocky: RocksStoreRef
      ): Result[void,HexaryError]
      {.gcsafe, raises: [OSError,IOError,KeyError].} =
  ## SST based bulk load on `rocksdb`.
  if rocky.isNil:
    return err(NoRocksDbBackend)
  let bulker = RockyBulkLoadRef.init(rocky)
  defer: bulker.destroy()
  if not bulker.begin(RockyBulkCache):
    let error = CannotOpenRocksDbBulkSession
    when extraTraceMessages:
      trace logTxt "rocksdb session initiation failed",
        error, info=bulker.lastError()
    return err(error)

  var
    lookup: Table[NodeKey,Blob]
    keyList = newSeq[NodeTag](data.len)
    inx = 0
  for (key,val) in data:
    if not lookup.hasKey key:
      lookup[key] = val
      keyList[inx] = key.to(NodeTag)
      inx.inc
  if lookup.len < inx:
    keyList.setLen(inx)
  keyList.sort(cmp)

  for n,nodeTag in keyList:
    let
      nodeKey = nodeTag.to(NodeKey)
      data = lookup[nodeKey]
    if not bulker.add(nodeKey.toContracthashKey.toOpenArray, data):
      let error = AddBulkItemFailed
      when extraTraceMessages:
        trace logTxt "rocksdb bulk load failure",
          n, dataLen=data.len, error, info=bulker.lastError()
      return err(error)

  if bulker.finish().isErr:
    let error = CommitBulkItemsFailed
    when extraTraceMessages:
      trace logTxt "rocksdb commit failure",
        dataLen=data.len, error, info=bulker.lastError()
    return err(error)
  ok()
# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

