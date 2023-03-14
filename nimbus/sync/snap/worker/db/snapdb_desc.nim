# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/tables,
  chronicles,
  eth/[common, p2p, trie/db, trie/nibbles],
  ../../../../db/[select_backend, storage_types],
  ../../../protocol,
  ../../range_desc,
  "."/[hexary_debug, hexary_desc, hexary_error, hexary_import, hexary_nearby,
       hexary_paths, rocky_bulk_load]

logScope:
  topics = "snap-db"

const
  extraTraceMessages = false or true

  RockyBulkCache* = "accounts.sst"
    ## Name of temporary file to accomodate SST records for `rocksdb`

type
  SnapDbRef* = ref object
    ## Global, re-usable descriptor
    keyMap: Table[RepairKey,uint]    ## For debugging only (will go away)
    db: TrieDatabaseRef              ## General database
    rocky: RocksStoreRef             ## Set if rocksdb is available

  SnapDbBaseRef* = ref object of RootRef
    ## Session descriptor
    xDb: HexaryTreeDbRef             ## Hexary database, memory based
    base: SnapDbRef                  ## Back reference to common parameters
    root*: NodeKey                   ## Session DB root node key

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

proc keyPp(a: RepairKey; pv: SnapDbRef): string =
  if a.isZero:
    return "ø"
  if not pv.keyMap.hasKey(a):
    pv.keyMap[a] = pv.keyMap.len.uint + 1
  result = if a.isNodeKey: "$" else: "@"
  noKeyError("pp(RepairKey)"):
    result &= $pv.keyMap[a]

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc clearRockyCacheFile(rocky: RocksStoreRef): bool =
  if not rocky.isNil:
    # A cache file might hang about from a previous crash
    try:
      discard rocky.clearCacheFile(RockyBulkCache)
      return true
    except OSError as e:
      error "Cannot clear rocksdb cache", exception=($e.name), msg=e.msg

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapDbRef;
    db: TrieDatabaseRef
      ): T =
  ## Main object constructor
  T(db: db)

proc init*(
    T: type SnapDbRef;
    db: ChainDb
      ): T =
  ## Variant of `init()` allowing bulk import on rocksdb backend
  result = T(db: db.trieDB, rocky: db.rocksStoreRef)
  if not result.rocky.clearRockyCacheFile():
    result.rocky = nil

proc init*(
    T: type HexaryTreeDbRef;
    pv: SnapDbRef;
      ): T =
  ## Constructor for inner hexary trie database
  let xDb = HexaryTreeDbRef()
  xDb.keyPp = proc(key: RepairKey): string = key.keyPp(pv) # will go away
  return xDb

proc init*(
    T: type HexaryTreeDbRef;
    ps: SnapDbBaseRef;
      ): T =
  ## Constructor variant
  HexaryTreeDbRef.init(ps.base)

# ---------------

proc init*(
    ps: SnapDbBaseRef;
    pv: SnapDbRef;
    root: NodeKey;
      ) =
  ## Session base constructor
  ps.base = pv
  ps.root = root
  ps.xDb = HexaryTreeDbRef.init(pv)

proc init*(
    T: type SnapDbBaseRef;
    ps: SnapDbBaseRef;
    root: NodeKey;
      ): T =
  ## Variant of session base constructor
  new result
  result.init(ps.base, root)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc hexaDb*(ps: SnapDbBaseRef): HexaryTreeDbRef =
  ## Getter, low level access to underlying session DB
  ps.xDb

proc rockDb*(ps: SnapDbBaseRef): RocksStoreRef =
  ## Getter, low level access to underlying persistent rock DB interface
  ps.base.rocky

proc kvDb*(ps: SnapDbBaseRef): TrieDatabaseRef =
  ## Getter, low level access to underlying persistent key-value DB
  ps.base.db

proc kvDb*(pv: SnapDbRef): TrieDatabaseRef =
  ## Getter, low level access to underlying persistent key-value DB
  pv.db

# ------------------------------------------------------------------------------
# Public functions, select sub-tables for persistent storage
# ------------------------------------------------------------------------------

proc toAccountsKey*(a: NodeKey): ByteArray33 =
  a.ByteArray32.snapSyncAccountKey.data

proc toStorageSlotsKey*(a: NodeKey): ByteArray33 =
  a.ByteArray32.snapSyncStorageSlotKey.data

proc toStateRootKey*(a: NodeKey): ByteArray33 =
  a.ByteArray32.snapSyncStateRootKey.data

template toOpenArray*(k: ByteArray32): openArray[byte] =
  k.toOpenArray(0, 31)

template toOpenArray*(k: ByteArray33): openArray[byte] =
  k.toOpenArray(0, 32)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbBackendRocksDb*(pv: SnapDbRef): bool =
  ## Returns `true` if rocksdb features are available
  not pv.rocky.isNil

proc dbBackendRocksDb*(ps: SnapDbBaseRef): bool =
  ## Returns `true` if rocksdb features are available
  not ps.base.rocky.isNil

proc mergeProofs*(
    xDb: HexaryTreeDbRef;     ## Session database
    root: NodeKey;            ## State root
    proof: seq[SnapProof];    ## Node records
    peer = Peer();            ## For log messages
    freeStandingOk = false;   ## Remove freestanding nodes
      ): Result[void,HexaryError]
      {.gcsafe, raises: [RlpError,KeyError].} =
  ## Import proof records (as received with snap message) into a hexary trie
  ## of the repair table. These hexary trie records can be extended to a full
  ## trie at a later stage and used for validating account data.
  var
    nodes: HashSet[RepairKey]
    refs = @[root.to(RepairKey)].toHashSet

  for n,rlpRec in proof:
    let report = xDb.hexaryImport(rlpRec.to(Blob), nodes, refs)
    if report.error != NothingSerious:
      let error = report.error
      trace "mergeProofs()", peer, item=n, proofs=proof.len, error
      return err(error)

  # Remove free standing nodes (if any)
  if 0 < nodes.len:
    let rest = nodes - refs
    if 0 < rest.len:
      if freeStandingOk:
        trace "mergeProofs() detected unrelated nodes", peer, nodes=nodes.len
        discard
      else:
        # Delete unreferenced nodes
        for nodeKey in nodes:
          xDb.tab.del(nodeKey)
        trace "mergeProofs() ignoring unrelated nodes", peer, nodes=nodes.len

  ok()


proc verifyLowerBound*(
    xDb: HexaryTreeDbRef;     ## Session database
    root: NodeKey;            ## State root
    base: NodeTag;            ## Before or at first account entry in `data`
    first: NodeTag;           ## First account/storage key
    peer = Peer();            ## For log messages
      ): Result[void,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Verify that `base` is to the left of the first leaf entry and there is
  ## nothing in between.
  var error: HexaryError

  let rc = base.hexaryNearbyRight(root, xDb)
  if rc.isErr:
    error = rc.error
  elif first == rc.value:
    return ok()
  else:
    error = LowerBoundProofError

  when extraTraceMessages:
    trace "verifyLowerBound()", peer, base=base.to(NodeKey).pp,
      first=first.to(NodeKey).pp, error
  err(error)


proc verifyNoMoreRight*(
    xDb: HexaryTreeDbRef;     ## Session database
    root: NodeKey;            ## State root
    base: NodeTag;            ## Before or at first account entry in `data`
    peer = Peer();            ## For log messages
      ): Result[void,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Verify that there is are no more leaf entries to the right of and
  ## including `base`.
  let
    root = root.to(RepairKey)
    base = base.to(NodeKey)
    rc = base.hexaryPath(root, xDb).hexaryNearbyRightMissing(xDb)
  if rc.isErr:
    return err(rc.error)
  if rc.value:
    return ok()

  let error = LowerBoundProofError
  when extraTraceMessages:
    trace "verifyLeftmostBound()", peer, base=base.pp, error
  err(error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
