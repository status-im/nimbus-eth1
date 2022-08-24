# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[algorithm, strutils, tables],
  chronicles,
  eth/[common/eth_types, trie/db],
  ../../../../db/[kvstore_rocksdb, storage_types],
  ../../../types,
  ../../range_desc,
  "."/[hexary_defs, hexary_desc, rocky_bulk_load]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

const
  RockyBulkCache = "accounts.sst"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(tag: NodeTag; T: type RepairKey): T =
  tag.to(NodeKey).to(RepairKey)

proc convertTo(key: RepairKey; T: type NodeKey): T =
  if key.isNodeKey:
    discard result.init(key.ByteArray33[1 .. 32])

proc convertTo(key: RepairKey; T: type NodeTag): T =
  if key.isNodeKey:
    result = UInt256.fromBytesBE(key.ByteArray33[1 .. 32]).T

# ------------------------------------------------------------------------------
# Private helpers for bulk load testing
# ------------------------------------------------------------------------------

proc chainDbHexaryKey(a: RepairKey): ByteArray32 =
  a.convertTo(NodeKey).ByteArray32

proc chainDbHexaryKey(a: NodeTag): ByteArray32 =
  a.to(NodeKey).ByteArray32

template toOpenArray*(k: ByteArray32): openArray[byte] =
  k.toOpenArray(0, 31)

# ------------------------------------------------------------------------------
# Public helperd
# ------------------------------------------------------------------------------

proc bulkStorageClearRockyCacheFile*(rocky: RocksStoreRef): bool =
  if not rocky.isNil:
    # A cache file might hang about from a previous crash
    try:
      discard rocky.clearCacheFile(RockyBulkCache)
      return true
    except OSError as e:
      error "Cannot clear rocksdb cache", exception=($e.name), msg=e.msg

# ------------------------------------------------------------------------------
# Public bulk store examples
# ------------------------------------------------------------------------------

proc bulkStorageHexaryNodesOnChainDb*(
    db: HexaryTreeDB;
    base: TrieDatabaseRef
      ): Result[void,HexaryDbError] =
  ## Bulk load using transactional `put()`
  let dbTx = base.beginTransaction
  defer: dbTx.commit

  for (key,value) in db.tab.pairs:
    if not key.isNodeKey:
      let error = UnresolvedRepairNode
      trace "Unresolved node in repair table", error
      return err(error)
    base.put(key.chainDbHexaryKey.toOpenArray, value.convertTo(Blob))
  ok()


proc bulkStorageHexaryNodesOnRockyDb*(
    db: HexaryTreeDB;
    rocky: RocksStoreRef
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,OSError,KeyError,ValueError].} =
  ## SST based bulk load on `rocksdb`.
  if rocky.isNil:
    return err(NoRocksDbBackend)
  let bulker = RockyBulkLoadRef.init(rocky)
  defer: bulker.destroy()
  if not bulker.begin(RockyBulkCache):
    let error = CannotOpenRocksDbBulkSession
    trace "Rocky hexary session initiation failed",
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
     key = nodeTag.chainDbHexaryKey()
     data = db.tab[nodeTag.to(RepairKey)].convertTo(Blob)
    if not bulker.add(key.toOpenArray, data):
      let error = AddBulkItemFailed
      trace "Rocky hexary bulk load failure",
        n, len=db.tab.len, error, info=bulker.lastError()
      return err(error)

  if bulker.finish().isErr:
    let error = CommitBulkItemsFailed
    trace "Rocky hexary commit failure",
      len=db.acc.len, error, info=bulker.lastError()
    return err(error)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

