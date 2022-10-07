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
  std/[algorithm, sequtils, sets, strutils, tables, times],
  chronos,
  eth/[common/eth_types, p2p, rlp],
  eth/trie/[db, nibbles],
  stew/byteutils,
  stint,
  rocksdb,
  ../../../../constants,
  ../../../../db/[kvstore_rocksdb, select_backend],
  "../../.."/[protocol, types],
  ../../range_desc,
  "."/[bulk_storage, hexary_desc, hexary_error, hexary_import,
       hexary_interpolate, hexary_inspect, hexary_paths, rocky_bulk_load]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

export
  HexaryDbError,
  TrieNodeStat

const
  extraTraceMessages = false or true

type
  SnapDbRef* = ref object
    ## Global, re-usable descriptor
    db: TrieDatabaseRef              ## General database
    rocky: RocksStoreRef             ## Set if rocksdb is available

  SnapDbSessionRef* = ref object
    ## Database session descriptor
    keyMap: Table[RepairKey,uint]    ## For debugging only (will go away)
    base: SnapDbRef                  ## Back reference to common parameters
    peer: Peer                       ## For log messages
    accRoot: NodeKey                 ## Current accounts root node
    accDb: HexaryTreeDbRef           ## Accounts database
    stoDb: HexaryTreeDbRef           ## Storage database

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc newHexaryTreeDbRef(ps: SnapDbSessionRef): HexaryTreeDbRef =
  HexaryTreeDbRef(keyPp: ps.stoDb.keyPp) # for debugging, will go away

proc to(h: Hash256; T: type NodeKey): T =
  h.data.T

proc convertTo(data: openArray[byte]; T: type Hash256): T =
  discard result.data.NodeKey.init(data) # size error => zero

template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

template noRlpExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except RlpError:
    return err(RlpEncoding)
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

template noPpError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops (" & info & ") " & $e.name & ": " & e.msg

proc toKey(a: RepairKey; ps: SnapDbSessionRef): uint =
  if not a.isZero:
    noPpError("pp(RepairKey)"):
      if not ps.keyMap.hasKey(a):
        ps.keyMap[a] = ps.keyMap.len.uint + 1
      result = ps.keyMap[a]

proc toKey(a: NodeKey; ps: SnapDbSessionRef): uint =
  a.to(RepairKey).toKey(ps)

proc toKey(a: NodeTag; ps: SnapDbSessionRef): uint =
  a.to(NodeKey).toKey(ps)


proc pp(a: NodeKey; ps: SnapDbSessionRef): string =
  if a.isZero: "ø" else:"$" & $a.toKey(ps)

proc pp(a: RepairKey; ps: SnapDbSessionRef): string =
  if a.isZero: "ø" elif a.isNodeKey: "$" & $a.toKey(ps) else: "@" & $a.toKey(ps)

proc pp(a: NodeTag; ps: SnapDbSessionRef): string =
  a.to(NodeKey).pp(ps)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc mergeProofs(
    peer: Peer,               ## For log messages
    db: HexaryTreeDbRef;      ## Database table
    root: NodeKey;            ## Root for checking nodes
    proof: seq[Blob];         ## Node records
    freeStandingOk = false;   ## Remove freestanding nodes
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError, KeyError].} =
  ## Import proof records (as received with snap message) into a hexary trie
  ## of the repair table. These hexary trie records can be extended to a full
  ## trie at a later stage and used for validating account data.
  var
    nodes: HashSet[RepairKey]
    refs = @[root.to(RepairKey)].toHashSet

  for n,rlpRec in proof:
    let rc = db.hexaryImport(rlpRec, nodes, refs)
    if rc.isErr:
      let error = rc.error
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
          db.tab.del(nodeKey)
        trace "mergeProofs() ignoring unrelated nodes", peer, nodes=nodes.len

  ok()


proc persistentAccounts(
    db: HexaryTreeDbRef;      ## Current table
    pv: SnapDbRef;            ## Persistent database
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,OSError,KeyError].} =
  ## Store accounts trie table on databse
  if pv.rocky.isNil:
    let rc = db.bulkStorageAccounts(pv.db)
    if rc.isErr: return rc
  else:
    let rc = db.bulkStorageAccountsRocky(pv.rocky)
    if rc.isErr: return rc
  ok()

proc persistentStorages(
    db: HexaryTreeDbRef;      ## Current table
    pv: SnapDbRef;            ## Persistent database
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,OSError,KeyError].} =
  ## Store accounts trie table on databse
  if pv.rocky.isNil:
    let rc = db.bulkStorageStorages(pv.db)
    if rc.isErr: return rc
  else:
    let rc = db.bulkStorageStoragesRocky(pv.rocky)
    if rc.isErr: return rc
  ok()


proc collectAccounts(
    peer: Peer,               ## for log messages
    base: NodeTag;
    acc: seq[PackedAccount];
      ): Result[seq[RLeafSpecs],HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Repack account records into a `seq[RLeafSpecs]` queue. The argument data
  ## `acc` are as received with the snap message `AccountRange`).
  ##
  ## The returned list contains leaf node information for populating a repair
  ## table. The accounts, together with some hexary trie records for proofs
  ## can be used for validating the argument account data.
  var rcAcc: seq[RLeafSpecs]

  if acc.len != 0:
    let pathTag0 = acc[0].accHash.to(NodeTag)

    # Verify lower bound
    if pathTag0 < base:
      let error = HexaryDbError.AccountSmallerThanBase
      trace "collectAccounts()", peer, base, accounts=acc.len, error
      return err(error)

    # Add base for the records (no payload). Note that the assumption
    # holds: `rcAcc[^1].tag <= base`
    if base < pathTag0:
      rcAcc.add RLeafSpecs(pathTag: base)

    # Check for the case that accounts are appended
    elif 0 < rcAcc.len and pathTag0 <= rcAcc[^1].pathTag:
      let error = HexaryDbError.AccountsNotSrictlyIncreasing
      trace "collectAccounts()", peer, base, accounts=acc.len, error
      return err(error)

    # Add first account
    rcAcc.add RLeafSpecs(pathTag: pathTag0, payload: acc[0].accBlob)

    # Veify & add other accounts
    for n in 1 ..< acc.len:
      let nodeTag = acc[n].accHash.to(NodeTag)

      if nodeTag <= rcAcc[^1].pathTag:
        let error = AccountsNotSrictlyIncreasing
        trace "collectAccounts()", peer, item=n, base, accounts=acc.len, error
        return err(error)

      rcAcc.add RLeafSpecs(pathTag: nodeTag, payload: acc[n].accBlob)

  ok(rcAcc)


proc collectStorageSlots(
    peer: Peer;
    slots: seq[SnapStorage];
      ): Result[seq[RLeafSpecs],HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Similar to `collectAccounts()`
  var rcSlots: seq[RLeafSpecs]

  if slots.len != 0:
    # Add initial account
    rcSlots.add RLeafSpecs(
      pathTag: slots[0].slotHash.to(NodeTag),
      payload: slots[0].slotData)

    # Veify & add other accounts
    for n in 1 ..< slots.len:
      let nodeTag = slots[n].slotHash.to(NodeTag)

      if nodeTag <= rcSlots[^1].pathTag:
        let error = SlotsNotSrictlyIncreasing
        trace "collectStorageSlots()", peer, item=n, slots=slots.len, error
        return err(error)

      rcSlots.add RLeafSpecs(pathTag: nodeTag, payload: slots[n].slotData)

  ok(rcSlots)


proc importStorageSlots*(
    ps: SnapDbSessionRef;     ## Re-usable session descriptor
    data: AccountSlots;       ## Account storage descriptor
    proof: SnapStorageProof;  ## Account storage proof
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError,KeyError].} =
  ## Preocess storage slots for a particular storage root
  let
    stoRoot = data.account.storageRoot.to(NodeKey)
  var
    slots: seq[RLeafSpecs]
    db = ps.newHexaryTreeDbRef()

  if 0 < proof.len:
    let rc = ps.peer.mergeProofs(db, stoRoot, proof)
    if rc.isErr:
      return err(rc.error)
  block:
    let rc = ps.peer.collectStorageSlots(data.data)
    if rc.isErr:
      return err(rc.error)
    slots = rc.value
  block:
    let rc = db.hexaryInterpolate(stoRoot, slots, bootstrap = (proof.len == 0))
    if rc.isErr:
      return err(rc.error)

  # Commit to main descriptor
  for k,v in db.tab.pairs:
    if not k.isNodeKey:
      return err(UnresolvedRepairNode)
    ps.stoDb.tab[k] = v

  ok()

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
  if not result.rocky.bulkStorageClearRockyCacheFile():
    result.rocky = nil

proc init*(
    T: type SnapDbSessionRef;
    pv: SnapDbRef;
    root: Hash256;
    peer: Peer = nil
      ): T =
  ## Start a new session, do some actions an then discard the session
  ## descriptor (probably after commiting data.)
  let desc = SnapDbSessionRef(
    base:    pv,
    peer:    peer,
    accRoot: root.to(NodeKey),
    accDb:   HexaryTreeDbRef(),
    stoDb:   HexaryTreeDbRef())

  # Debugging, might go away one time ...
  desc.accDb.keyPp = proc(key: RepairKey): string = key.pp(desc)
  desc.stoDb.keyPp = desc.accDb.keyPp

  return desc

proc dup*(
    ps: SnapDbSessionRef;
    root: Hash256;
    peer: Peer;
      ): SnapDbSessionRef =
  ## Resume a session with different `root` key and `peer`. This new session
  ## will access the same memory database as the `ps` argument session.
  SnapDbSessionRef(
    base:    ps.base,
    peer:    peer,
    accRoot: root.to(NodeKey),
    accDb:   ps.accDb,
    stoDb:   ps.stoDb)

proc dup*(
    ps: SnapDbSessionRef;
    root: Hash256;
      ): SnapDbSessionRef =
  ## Variant of `dup()` without the `peer` argument.
  ps.dup(root, ps.peer)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbBackendRocksDb*(pv: SnapDbRef): bool =
  ## Returns `true` if rocksdb features are available
  not pv.rocky.isNil

proc dbBackendRocksDb*(ps: SnapDbSessionRef): bool =
  ## Returns `true` if rocksdb features are available
  not ps.base.rocky.isNil

proc importAccounts*(
    ps: SnapDbSessionRef;     ## Re-usable session descriptor
    base: NodeTag;            ## before or at first account entry in `data`
    data: PackedAccountRange; ## re-packed `snap/1 ` reply data
    persistent = false;       ## store data on disk
      ): Result[void,HexaryDbError] =
  ## Validate and import accounts (using proofs as received with the snap
  ## message `AccountRange`). This function accumulates data in a memory table
  ## which can be written to disk with the argument `persistent` set `true`. The
  ## memory table is held in the descriptor argument`ps`.
  ##
  ## Note that the `peer` argument is for log messages, only.
  var accounts: seq[RLeafSpecs]
  try:
    if 0 < data.proof.len:
      let rc = ps.peer.mergeProofs(ps.accDb, ps.accRoot, data.proof)
      if rc.isErr:
        return err(rc.error)
    block:
      let rc = ps.peer.collectAccounts(base, data.accounts)
      if rc.isErr:
        return err(rc.error)
      accounts = rc.value
    block:
      let rc = ps.accDb.hexaryInterpolate(
        ps.accRoot, accounts, bootstrap = (data.proof.len == 0))
      if rc.isErr:
        return err(rc.error)

    if persistent and 0 < ps.accDb.tab.len:
      let rc = ps.accDb.persistentAccounts(ps.base)
      if rc.isErr:
        return err(rc.error)

  except RlpError:
    return err(RlpEncoding)
  except KeyError as e:
    raiseAssert "Not possible @ importAccounts: " & e.msg
  except OSError as e:
    trace "Import Accounts exception", peer=ps.peer, name=($e.name), msg=e.msg
    return err(OSErrorException)

  when extraTraceMessages:
    trace "Accounts and proofs ok", peer=ps.peer,
      root=ps.accRoot.ByteArray32.toHex,
      proof=data.proof.len, base, accounts=data.accounts.len
  ok()

proc importAccounts*(
    pv: SnapDbRef;            ## Base descriptor on `BaseChainDB`
    peer: Peer,               ## for log messages
    root: Hash256;            ## state root
    base: NodeTag;            ## before or at first account entry in `data`
    data: PackedAccountRange; ## re-packed `snap/1 ` reply data
      ): Result[void,HexaryDbError] =
  ## Variant of `importAccounts()`
  SnapDbSessionRef.init(
    pv, root, peer).importAccounts(base, data, persistent=true)



proc importStorages*(
    ps: SnapDbSessionRef;      ## Re-usable session descriptor
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
    persistent = false;        ## store data on disk
      ): Result[void,seq[(int,HexaryDbError)]] =
  ## Validate and import storage slots (using proofs as received with the snap
  ## message `StorageRanges`). This function accumulates data in a memory table
  ## which can be written to disk with the argument `persistent` set `true`. The
  ## memory table is held in the descriptor argument`ps`.
  ##
  ## Note that the `peer` argument is for log messages, only.
  ##
  ## On error, the function returns a non-empty list of slot IDs and error
  ## codes for the entries that could not be processed. If the slot ID is -1,
  ## the error returned is not related to a slot. If any, this -1 entry is
  ## always the last in the list.
  let
    nItems = data.storages.len
    sTop = nItems - 1
  if 0 <= sTop:
    var
      errors: seq[(int,HexaryDbError)]
      slotID = -1 # so excepions see the current solt ID
    try:
      for n in 0 ..< sTop:
        # These ones never come with proof data
        slotID = n
        let rc = ps.importStorageSlots(data.storages[slotID], @[])
        if rc.isErr:
          let error = rc.error
          trace "Storage slots item fails", peer=ps.peer, slotID, nItems,
            slots=data.storages[slotID].data.len, proofs=0, error
          errors.add (slotID,error)

      # Final one might come with proof data
      block:
        slotID = sTop
        let rc = ps.importStorageSlots(data.storages[slotID], data.proof)
        if rc.isErr:
          let error = rc.error
          trace "Storage slots last item fails", peer=ps.peer, nItems,
            slots=data.storages[sTop].data.len, proofs=data.proof.len, error
          errors.add (slotID,error)

      # Store to disk
      if persistent and 0 < ps.stoDb.tab.len:
        slotID = -1
        let rc = ps.stoDb.persistentStorages(ps.base)
        if rc.isErr:
          errors.add (slotID,rc.error)

    except RlpError:
      errors.add (slotID,RlpEncoding)
    except KeyError as e:
      raiseAssert "Not possible @ importAccounts: " & e.msg
    except OSError as e:
      trace "Import Accounts exception", peer=ps.peer, name=($e.name), msg=e.msg
      errors.add (slotID,RlpEncoding)

    if 0 < errors.len:
      # So non-empty error list is guaranteed
      return err(errors)

  when extraTraceMessages:
    trace "Storage slots imported", peer=ps.peer,
      slots=data.storages.len, proofs=data.proof.len
  ok()

proc importStorages*(
    pv: SnapDbRef;             ## Base descriptor on `BaseChainDB`
    peer: Peer,                ## For log messages, only
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
      ): Result[void,seq[(int,HexaryDbError)]] =
  ## Variant of `importStorages()`
  SnapDbSessionRef.init(
    pv, Hash256(), peer).importStorages(data, persistent=true)



proc importRawNodes*(
    ps: SnapDbSessionRef;      ## Re-usable session descriptor
    nodes: openArray[Blob];    ## Node records
    persistent = false;        ## store data on disk
      ): Result[void,seq[(int,HexaryDbError)]] =
  ## ...
  var
    errors: seq[(int,HexaryDbError)]
    nodeID = -1
  let
    db = ps.newHexaryTreeDbRef()
  try:
    # Import nodes
    for n,rec in nodes:
      nodeID = n
      let rc = db.hexaryImport(rec)
      if rc.isErr:
        let error = rc.error
        trace "importRawNodes()", peer=ps.peer, item=n, nodes=nodes.len, error
        errors.add (nodeID,error)

    # Store to disk
    if persistent and 0 < db.tab.len:
      nodeID = -1
      let rc = db.persistentAccounts(ps.base)
      if rc.isErr:
        errors.add (nodeID,rc.error)

  except RlpError:
    errors.add (nodeID,RlpEncoding)
  except KeyError as e:
    raiseAssert "Not possible @ importAccounts: " & e.msg
  except OSError as e:
    trace "Import Accounts exception", peer=ps.peer, name=($e.name), msg=e.msg
    errors.add (nodeID,RlpEncoding)

  if 0 < errors.len:
    return err(errors)

  trace "Raw nodes imported", peer=ps.peer, nodes=nodes.len
  ok()

proc importRawNodes*(
    pv: SnapDbRef;               ## Base descriptor on `BaseChainDB`
    peer: Peer,                      ## For log messages, only
    nodes: openArray[Blob];          ## Node records
      ): Result[void,seq[(int,HexaryDbError)]] =
  ## Variant of `importRawNodes()` for persistent storage.
  SnapDbSessionRef.init(
    pv, Hash256(), peer).importRawNodes(nodes, persistent=true)


proc inspectAccountsTrie*(
    ps: SnapDbSessionRef;         ## Re-usable session descriptor
    pathList = seq[Blob].default; ## Starting nodes for search
    maxLeafPaths = 0;             ## Record leaves with proper 32 bytes path
    persistent = false;           ## Read data from disk
    ignoreError = false;          ## Always return partial results if available
      ): Result[TrieNodeStat, HexaryDbError] =
  ## Starting with the argument list `pathSet`, find all the non-leaf nodes in
  ## the hexary trie which have at least one node key reference missing in
  ## the trie database. Argument `pathSet` list entries that do not refer to a
  ## valid node are silently ignored.
  ##
  let peer = ps.peer
  var stats: TrieNodeStat
  noRlpExceptionOops("inspectAccountsTrie()"):
    if persistent:
      let getFn: HexaryGetFn = proc(key: Blob): Blob = ps.base.db.get(key)
      stats = getFn.hexaryInspectTrie(ps.accRoot, pathList, maxLeafPaths)
    else:
      stats = ps.accDb.hexaryInspectTrie(ps.accRoot, pathList, maxLeafPaths)

  block checkForError:
    let error = block:
      if stats.stopped:
        TrieLoopAlert
      elif stats.level == 0:
        TrieIsEmpty
      else:
        break checkForError
    trace "Inspect account trie failed", peer, nPathList=pathList.len,
      nDangling=stats.dangling.len, leaves=stats.leaves.len,
      maxleaves=maxLeafPaths, stoppedAt=stats.level, error
    return err(error)

  when extraTraceMessages:
    trace "Inspect account trie ok", peer, nPathList=pathList.len,
      nDangling=stats.dangling.len, leaves=stats.leaves.len,
      maxleaves=maxLeafPaths, level=stats.level
  return ok(stats)

proc inspectAccountsTrie*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer;                   ## For log messages, only
    root: Hash256;                ## state root
    pathList = seq[Blob].default; ## Starting paths for search
    maxLeafPaths = 0;             ## Record leaves with proper 32 bytes path
    ignoreError = false;          ## Always return partial results when avail.
      ): Result[TrieNodeStat, HexaryDbError] =
  ## Variant of `inspectAccountsTrie()` for persistent storage.
  SnapDbSessionRef.init(
    pv, root, peer).inspectAccountsTrie(
      pathList, maxLeafPaths, persistent=true, ignoreError)


proc getAccountNodeKey*(
    ps: SnapDbSessionRef;         ## Re-usable session descriptor
    path: Blob;                   ## Partial node path
    persistent = false;           ## Read data from disk
      ): Result[NodeKey,HexaryDbError] =
  ## For a partial node path argument `path`, return the raw node key.
  var rc: Result[NodeKey,void]
  noRlpExceptionOops("inspectAccountsPath()"):
    if persistent:
      let getFn: HexaryGetFn = proc(key: Blob): Blob = ps.base.db.get(key)
      rc = getFn.hexaryInspectPath(ps.accRoot, path)
    else:
      rc = ps.accDb.hexaryInspectPath(ps.accRoot, path)
  if rc.isOk:
    return ok(rc.value)
  err(NodeNotFound)

proc getAccountNodeKey*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer;                   ## For log messages, only
    root: Hash256;                ## state root
    path: Blob;                   ## Partial node path
      ): Result[NodeKey,HexaryDbError] =
  ## Variant of `inspectAccountsPath()` for persistent storage.
  SnapDbSessionRef.init(
    pv, root, peer).getAccountNodeKey(path, persistent=true)


proc getAccountData*(
    ps: SnapDbSessionRef;         ## Re-usable session descriptor
    path: NodeKey;                ## Account to visit
    persistent = false;           ## Read data from disk
      ): Result[Account,HexaryDbError] =
  ## Fetch account data.
  ##
  ## Caveat: There is no unit test yet for the non-persistent version
  let peer = ps.peer
  var acc: Account

  noRlpExceptionOops("getAccountData()"):
    var leaf: Blob
    if persistent:
      let getFn: HexaryGetFn = proc(key: Blob): Blob = ps.base.db.get(key)
      leaf = path.hexaryPath(ps.accRoot, getFn).leafData
    else:
      leaf = path.hexaryPath(ps.accRoot.to(RepairKey),ps.accDb).leafData

    if leaf.len == 0:
      return err(AccountNotFound)
    acc = rlp.decode(leaf,Account)

  return ok(acc)

proc getAccountData*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer,                   ## For log messages, only
    root: Hash256;                ## state root
    path: NodeKey;                ## Account to visit
      ): Result[Account,HexaryDbError] =
  ## Variant of `getAccount()` for persistent storage.
  SnapDbSessionRef.init(pv, root, peer).getAccountData(path, persistent=true)

# ------------------------------------------------------------------------------
# Public functions: additional helpers
# ------------------------------------------------------------------------------

proc sortMerge*(base: openArray[NodeTag]): NodeTag =
  ## Helper for merging several `(NodeTag,seq[PackedAccount])` data sets
  ## so that there are no overlap which would be rejected by `merge()`.
  ##
  ## This function selects a `NodeTag` from a list.
  result = high(NodeTag)
  for w in base:
    if w < result:
      result = w

proc sortMerge*(acc: openArray[seq[PackedAccount]]): seq[PackedAccount] =
  ## Helper for merging several `(NodeTag,seq[PackedAccount])` data sets
  ## so that there are no overlap which would be rejected by `merge()`.
  ##
  ## This function flattens and sorts the argument account lists.
  noKeyError("sortMergeAccounts"):
    var accounts: Table[NodeTag,PackedAccount]
    for accList in acc:
      for item in accList:
        accounts[item.accHash.to(NodeTag)] = item
    result = toSeq(accounts.keys).sorted(cmp).mapIt(accounts[it])

proc getChainDbAccount*(
    ps: SnapDbSessionRef;
    accHash: Hash256
      ): Result[Account,HexaryDbError] =
  ## Fetch account via `BaseChainDB`
  ps.getAccountData(accHash.to(NodeKey),persistent=true)

proc nextChainDbKey*(
    ps: SnapDbSessionRef;
    accHash: Hash256
      ): Result[Hash256,HexaryDbError] =
  ## Fetch the account path on the `BaseChainDB`, the one next to the
  ## argument account.
  noRlpExceptionOops("getChainDbAccount()"):
    let
      getFn: HexaryGetFn = proc(key: Blob): Blob = ps.base.db.get(key)
      path = accHash.to(NodeKey)
                    .hexaryPath(ps.accRoot, getFn)
                    .next(getFn)
                    .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256))

  err(AccountNotFound)

proc prevChainDbKey*(
    ps: SnapDbSessionRef;
    accHash: Hash256
      ): Result[Hash256,HexaryDbError] =
  ## Fetch the account path on the `BaseChainDB`, the one before to the
  ## argument account.
  noRlpExceptionOops("getChainDbAccount()"):
    let
      getFn: HexaryGetFn = proc(key: Blob): Blob = ps.base.db.get(key)
      path = accHash.to(NodeKey)
                    .hexaryPath(ps.accRoot, getFn)
                    .prev(getFn)
                    .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256))

  err(AccountNotFound)

# ------------------------------------------------------------------------------
# Debugging (and playing with the hexary database)
# ------------------------------------------------------------------------------

proc assignPrettyKeys*(ps: SnapDbSessionRef) =
  ## Prepare foe pretty pringing/debugging. Run early enough this function
  ## sets the root key to `"$"`, for instance.
  noPpError("validate(1)"):
    # Make keys assigned in pretty order for printing
    var keysList = toSeq(ps.accDb.tab.keys)
    let rootKey = ps.accRoot.to(RepairKey)
    discard rootKey.toKey(ps)
    if ps.accDb.tab.hasKey(rootKey):
      keysList = @[rootKey] & keysList
    for key in keysList:
      let node = ps.accDb.tab[key]
      discard key.toKey(ps)
      case node.kind:
      of Branch: (for w in node.bLink: discard w.toKey(ps))
      of Extension: discard node.eLink.toKey(ps)
      of Leaf: discard

proc dumpPath*(ps: SnapDbSessionRef; key: NodeTag): seq[string] =
  ## Pretty print helper compiling the path into the repair tree for the
  ## argument `key`.
  noPpError("dumpPath"):
    let rPath= key.to(NodeKey).hexaryPath(ps.accRoot.to(RepairKey), ps.accDb)
    result = rPath.path.mapIt(it.pp(ps.accDb)) & @["(" & rPath.tail.pp & ")"]

proc dumpAccDB*(ps: SnapDbSessionRef; indent = 4): string =
  ## Dump the entries from the a generic accounts trie.
  ps.accDb.pp(ps.accRoot,indent)

proc getAcc*(ps: SnapDbSessionRef): HexaryTreeDbRef =
  ## Low level access to accounts DB
  ps.accDb

proc hexaryPpFn*(ps: SnapDbSessionRef): HexaryPpFn =
  ## Key mapping function used in `HexaryTreeDB`
  ps.accDb.keyPp

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
