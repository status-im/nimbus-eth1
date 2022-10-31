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
  std/tables,
  chronicles,
  eth/[common, p2p, rlp],
  ../../../protocol,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_import, hexary_inspect,
       hexary_interpolate, hexary_paths, snapdb_desc, snapdb_persistent]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

const
  extraTraceMessages = false or true

type
  SnapDbStorageSlotsRef* = ref object of SnapDbBaseRef
    peer: Peer                  ## For log messages
    accKey: NodeKey             ## Accounts address hash (curr.unused)
    getClsFn: StorageSlotsGetFn ## Persistent database `get()` closure

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(h: Hash256; T: type NodeKey): T =
  h.data.T

proc convertTo(data: openArray[byte]; T: type Hash256): T =
  discard result.data.NodeKey.init(data) # size error => zero

proc getFn(ps: SnapDbStorageSlotsRef; accKey: NodeKey): HexaryGetFn =
  ## Capture `accKey` argument for `GetClsFn` closure => `HexaryGetFn`
  return proc(key: openArray[byte]): Blob = ps.getClsFn(accKey,key)


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

template noGenericExOrKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc persistentStorageSlots(
    db: HexaryTreeDbRef;       ## Current table
    ps: SnapDbStorageSlotsRef; ## For persistent database
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,OSError,KeyError].} =
  ## Store accounts trie table on databse
  if ps.rockDb.isNil:
    let rc = db.persistentStorageSlotsPut(ps.kvDb)
    if rc.isErr: return rc
  else:
    let rc = db.persistentStorageSlotsPut(ps.rockDb)
    if rc.isErr: return rc
  ok()


proc collectStorageSlots(
    peer: Peer;               ## for log messages
    base: NodeTag;            ## before or at first account entry in `data`
    slotLists: seq[SnapStorage];
      ): Result[seq[RLeafSpecs],HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Similar to `collectAccounts()`
  var rcSlots: seq[RLeafSpecs]

  if slotLists.len != 0:
    let pathTag0 = slotLists[0].slotHash.to(NodeTag)

    # Verify lower bound
    if pathTag0 < base:
      let error = LowerBoundAfterFirstEntry
      trace "collectStorageSlots()", peer, base, item=0,
        nSlotLists=slotLists.len, error
      return err(error)

    # Add initial account
    rcSlots.add RLeafSpecs(
      pathTag: slotLists[0].slotHash.to(NodeTag),
      payload: slotLists[0].slotData)

    # Veify & add other accounts
    for n in 1 ..< slotLists.len:
      let nodeTag = slotLists[n].slotHash.to(NodeTag)

      if nodeTag <= rcSlots[^1].pathTag:
        let error = SlotsNotSrictlyIncreasing
        trace "collectStorageSlots()", peer, item=n,
          nSlotLists=slotLists.len, error
        return err(error)

      rcSlots.add RLeafSpecs(
        pathTag: nodeTag,
        payload: slotLists[n].slotData)

  ok(rcSlots)


proc importStorageSlots(
    ps: SnapDbStorageSlotsRef; ## Re-usable session descriptor
    base: NodeTag;             ## before or at first account entry in `data`
    data: AccountSlots;        ## Account storage descriptor
    proof: SnapStorageProof;   ## Account storage proof
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,RlpError,KeyError].} =
  ## Preocess storage slots for a particular storage root
  let
    tmpDb = SnapDbBaseRef.init(ps, data.account.storageRoot.to(NodeKey))
  var
    slots: seq[RLeafSpecs]
  if 0 < proof.len:
    let rc = tmpDb.mergeProofs(ps.peer, proof)
    if rc.isErr:
      return err(rc.error)
  block:
    let rc = ps.peer.collectStorageSlots(base, data.data)
    if rc.isErr:
      return err(rc.error)
    slots = rc.value
  if 0 < slots.len:
    let rc = tmpDb.hexaDb.hexaryInterpolate(
      tmpDb.root, slots, bootstrap = (proof.len == 0))
    if rc.isErr:
      return err(rc.error)
  # Verify that `base` is to the left of the first storage slot and there is
  # nothing in between. Without proof, there can only be a complete set/list
  # of storage slots. There must be a proof for an empty list.
  if 0 < proof.len:
    let rc = block:
      if 0 < slots.len:
        tmpDb.verifyLowerBound(ps.peer, base, slots[0].pathTag)
      else:
        tmpDb.verifyNoMoreRight(ps.peer, base)
    if rc.isErr:
      return err(rc.error)
  elif slots.len == 0:
    return err(LowerBoundProofError)

  # Commit to main descriptor
  for k,v in tmpDb.hexaDb.tab.pairs:
    if not k.isNodeKey:
      return err(UnresolvedRepairNode)
    ps.hexaDb.tab[k] = v

  ok()

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapDbStorageSlotsRef;
    pv: SnapDbRef;
    accKey: NodeKey;
    root: Hash256;
    peer: Peer = nil
      ): T =
  ## Constructor, starts a new accounts session.
  let db = pv.kvDb

  new result
  result.init(pv, root.to(NodeKey))
  result.peer = peer
  result.accKey = accKey
  result.getClsFn = db.persistentStorageSlotsGetFn()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc importStorageSlots*(
    ps: SnapDbStorageSlotsRef; ## Re-usable session descriptor
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
    persistent = false;        ## store data on disk
      ): seq[HexaryNodeReport] =
  ## Validate and import storage slots (using proofs as received with the snap
  ## message `StorageRanges`). This function accumulates data in a memory table
  ## which can be written to disk with the argument `persistent` set `true`. The
  ## memory table is held in the descriptor argument`ps`.
  ##
  ## If there were an error when processing a particular argument `data` item,
  ## it will be reported with the return value providing argument slot/index
  ## end error code.
  ##
  ## If there was an error soring persistent data, the last report item will
  ## have an error code, only.
  ##
  ## TODO:
  ##   Reconsider how to handle the persistant storage trie, see
  ##   github.com/status-im/nim-eth/issues/9#issuecomment-814573755
  ##
  let
    peer = ps.peer
    nItems = data.storages.len
    sTop = nItems - 1
  var
    itemInx: Option[int]
  if 0 <= sTop:
    try:
      for n in 0 ..< sTop:
        # These ones always come without proof data => `NodeTag.default`
        itemInx = some(n)
        let rc = ps.importStorageSlots(
          NodeTag.default, data.storages[n], @[])
        if rc.isErr:
          result.add HexaryNodeReport(slot: itemInx, error: rc.error)
          trace "Storage slots item fails", peer, itemInx=n, nItems,
            nSlots=data.storages[n].data.len, proofs=0,
            error=rc.error, nErrors=result.len

      # Final one might come with proof data
      block:
        itemInx = some(sTop)
        let rc = ps.importStorageSlots(
          data.base, data.storages[sTop], data.proof)
        if rc.isErr:
          result.add HexaryNodeReport(slot: itemInx, error: rc.error)
          trace "Storage slots last item fails", peer, itemInx=sTop, nItems,
            nSlots=data.storages[sTop].data.len, proofs=data.proof.len,
            error=rc.error, nErrors=result.len

      # Store to disk
      if persistent and 0 < ps.hexaDb.tab.len:
        itemInx = none(int)
        let rc = ps.hexaDb.persistentStorageSlots(ps)
        if rc.isErr:
          result.add HexaryNodeReport(slot: itemInx, error: rc.error)

    except RlpError:
      result.add HexaryNodeReport(slot: itemInx, error: RlpEncoding)
      trace "Storage slot node error", peer, itemInx, nItems,
        nSlots=data.storages[sTop].data.len, proofs=data.proof.len,
        error=RlpEncoding, nErrors=result.len
    except KeyError as e:
      raiseAssert "Not possible @ importStorages: " & e.msg
    except OSError as e:
      result.add HexaryNodeReport(slot: itemInx, error: OSErrorException)
      error "Import storage slots exception", peer, itemInx, nItems,
        name=($e.name), msg=e.msg, nErrors=result.len

  #when extraTraceMessages:
  #  if result.len == 0:
  #    trace "Storage slots imported", peer, nItems,
  #      nSlotLists=data.storages.len, proofs=data.proof.len

proc importStorageSlots*(
    pv: SnapDbRef;             ## Base descriptor on `BaseChainDB`
    peer: Peer;                ## For log messages, only
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
      ): seq[HexaryNodeReport] =
  ## Variant of `importStorages()`
  SnapDbStorageSlotsRef.init(
    pv,  Hash256().to(NodeKey), Hash256(), peer).importStorageSlots(
      data, persistent = true)


proc importRawStorageSlotsNodes*(
    ps: SnapDbStorageSlotsRef;   ## Re-usable session descriptor
    nodes: openArray[NodeSpecs]; ## List of `(key,data)` records
    reportNodes = {Leaf};        ## Additional node types to report
    persistent = false;          ## store data on disk
      ): seq[HexaryNodeReport] =
  ## Store data nodes given as argument `nodes` on the persistent database.
  ##
  ## If there were an error when processing a particular argument `notes` item,
  ## it will be reported with the return value providing argument slot/index,
  ## node type, end error code.
  ##
  ## If there was an error soring persistent data, the last report item will
  ## have an error code, only.
  ##
  ## Additional node items might be reported if the node type is in the
  ## argument set `reportNodes`. These reported items will have no error
  ## code set (i.e. `NothingSerious`.)
  ##
  let
    peer = ps.peer
    db = HexaryTreeDbRef.init(ps)
    nItems = nodes.len
  var
    nErrors = 0
    slot: Option[int]
  try:
    # Import nodes
    for n,node in nodes:
      if 0 < node.data.len: # otherwise ignore empty placeholder
        slot = some(n)
        var rep = db.hexaryImport(node)
        if rep.error != NothingSerious:
          rep.slot = slot
          result.add rep
          nErrors.inc
          trace "Error importing storage slots nodes", peer, inx=n, nItems,
            error=rep.error, nErrors
        elif rep.kind.isSome and rep.kind.unsafeGet in reportNodes:
          rep.slot = slot
          result.add rep

    # Store to disk
    if persistent and 0 < db.tab.len:
      slot = none(int)
      let rc = db.persistentStorageSlots(ps)
      if rc.isErr:
        result.add HexaryNodeReport(slot: slot, error: rc.error)

  except RlpError:
    result.add HexaryNodeReport(slot: slot, error: RlpEncoding)
    nErrors.inc
    trace "Error importing storage slots nodes", peer, slot, nItems,
      error=RlpEncoding, nErrors
  except KeyError as e:
    raiseAssert "Not possible @ importRawSorageSlotsNodes: " & e.msg
  except OSError as e:
    result.add HexaryNodeReport(slot: slot, error: OSErrorException)
    nErrors.inc
    error "Import storage slots nodes exception", peer, slot, nItems,
      name=($e.name), msg=e.msg, nErrors

  when extraTraceMessages:
    if nErrors == 0:
      trace "Raw storage slots nodes imported", peer, slot, nItems,
        report=result.len

proc importRawStorageSlotsNodes*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer,                   ## For log messages, only
    accKey: NodeKey;              ## Account key
    nodes: openArray[NodeSpecs];  ## List of `(key,data)` records
    reportNodes = {Leaf};         ## Additional node types to report
      ): seq[HexaryNodeReport] =
  ## Variant of `importRawNodes()` for persistent storage.
  SnapDbStorageSlotsRef.init(
    pv, accKey, Hash256(), peer).importRawStorageSlotsNodes(
      nodes, reportNodes, persistent=true)


proc inspectStorageSlotsTrie*(
    ps: SnapDbStorageSlotsRef;    ## Re-usable session descriptor
    pathList = seq[Blob].default; ## Starting nodes for search
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
  noRlpExceptionOops("inspectStorageSlotsTrie()"):
    if persistent:
      stats = ps.getFn(ps.accKey).hexaryInspectTrie(ps.root, pathList)
    else:
      stats = ps.hexaDb.hexaryInspectTrie(ps.root, pathList)

  block checkForError:
    var error = TrieIsEmpty
    if stats.stopped:
      error = TrieLoopAlert
      trace "Inspect storage slots trie failed", peer, nPathList=pathList.len,
        nDangling=stats.dangling.len, stoppedAt=stats.level
    elif 0 < stats.level:
      break checkForError
    if ignoreError:
      return ok(stats)
    return err(error)

  #when extraTraceMessages:
  #  trace "Inspect storage slots trie ok", peer, nPathList=pathList.len,
  #    nDangling=stats.dangling.len, level=stats.level

  return ok(stats)

proc inspectStorageSlotsTrie*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer;                   ## For log messages, only
    accKey: NodeKey;              ## Account key
    root: Hash256;                ## state root
    pathList = seq[Blob].default; ## Starting paths for search
    ignoreError = false;          ## Always return partial results when avail.
      ): Result[TrieNodeStat, HexaryDbError] =
  ## Variant of `inspectStorageSlotsTrieTrie()` for persistent storage.
  SnapDbStorageSlotsRef.init(
    pv, accKey, root, peer).inspectStorageSlotsTrie(
      pathList, persistent=true, ignoreError)


proc getStorageSlotsNodeKey*(
    ps: SnapDbStorageSlotsRef;    ## Re-usable session descriptor
    path: Blob;                   ## Partial node path
    persistent = false;           ## Read data from disk
      ): Result[NodeKey,HexaryDbError] =
  ## For a partial node path argument `path`, return the raw node key.
  var rc: Result[NodeKey,void]
  noRlpExceptionOops("getStorageSlotsNodeKey()"):
    if persistent:
      rc = ps.getFn(ps.accKey).hexaryInspectPath(ps.root, path)
    else:
      rc = ps.hexaDb.hexaryInspectPath(ps.root, path)
  if rc.isOk:
    return ok(rc.value)
  err(NodeNotFound)

proc getStorageSlotsNodeKey*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer;                   ## For log messages, only
    accKey: NodeKey;              ## Account key
    root: Hash256;                ## state root
    path: Blob;                   ## Partial node path
      ): Result[NodeKey,HexaryDbError] =
  ## Variant of `getStorageSlotsNodeKey()` for persistent storage.
  SnapDbStorageSlotsRef.init(
    pv, accKey, root, peer).getStorageSlotsNodeKey(path, persistent=true)


proc getStorageSlotsData*(
    ps: SnapDbStorageSlotsRef; ## Re-usable session descriptor
    path: NodeKey;             ## Account to visit
    persistent = false;        ## Read data from disk
      ): Result[Account,HexaryDbError] =
  ## Fetch storage slots data.
  ##
  ## Caveat: There is no unit test yet
  let peer = ps.peer
  var acc: Account

  noRlpExceptionOops("getStorageSlotsData()"):
    var leaf: Blob
    if persistent:
      leaf = path.hexaryPath(ps.root, ps.getFn(ps.accKey)).leafData
    else:
      leaf = path.hexaryPath(ps.root.to(RepairKey),ps.hexaDb).leafData

    if leaf.len == 0:
      return err(AccountNotFound)
    acc = rlp.decode(leaf,Account)

  return ok(acc)

proc getStorageSlotsData*(
    pv: SnapDbRef;             ## Base descriptor on `BaseChainDB`
    peer: Peer,                ## For log messages, only
    accKey: NodeKey;              ## Account key
    root: Hash256;             ## state root
    path: NodeKey;             ## Account to visit
      ): Result[Account,HexaryDbError] =
  ## Variant of `getStorageSlotsData()` for persistent storage.
  SnapDbStorageSlotsRef.init(
    pv, accKey, root, peer).getStorageSlotsData(path, persistent=true)


proc haveStorageSlotsData*(
    ps: SnapDbStorageSlotsRef; ## Re-usable session descriptor
    persistent = false;        ## Read data from disk
      ): bool =
  ## Return `true` if there is at least one intermediate hexary node for this
  ## accounts storage slots trie.
  ##
  ## Caveat: There is no unit test yet
  noGenericExOrKeyError("haveStorageSlotsData()"):
    if persistent:
      let getFn = ps.getFn(ps.accKey)
      return 0 < ps.root.ByteArray32.getFn().len
    else:
      return ps.hexaDb.tab.hasKey(ps.root.to(RepairKey))

proc haveStorageSlotsData*(
    pv: SnapDbRef;             ## Base descriptor on `BaseChainDB`
    peer: Peer,                ## For log messages, only
    accKey: NodeKey;              ## Account key
    root: Hash256;             ## state root
      ): bool =
  ## Variant of `haveStorageSlotsData()` for persistent storage.
  SnapDbStorageSlotsRef.init(
    pv, accKey, root, peer).haveStorageSlotsData(persistent=true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
