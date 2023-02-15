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
  stew/interval_set,
  ../../../protocol,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_envelope, hexary_import,
       hexary_inspect, hexary_interpolate, hexary_paths, snapdb_desc,
       snapdb_persistent]

{.push raises: [].}

logScope:
  topics = "snap-db"

const
  extraTraceMessages = false or true

type
  SnapDbStorageSlotsRef* = ref object of SnapDbBaseRef
    peer: Peer                  ## For log messages
    accKey: NodeKey             ## Accounts address hash (curr.unused)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(h: Hash256; T: type NodeKey): T =
  h.data.T

#proc convertTo(data: openArray[byte]; T: type Hash256): T =
#  discard result.data.NodeKey.init(data) # size error => zero

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except RlpError:
    return err(RlpEncoding)
  except CatchableError as e:
    return err(SlotsNotFound)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc persistentStorageSlots(
    db: HexaryTreeDbRef;       ## Current table
    ps: SnapDbStorageSlotsRef; ## For persistent database
      ): Result[void,HexaryError]
      {.gcsafe, raises: [OSError,IOError,KeyError].} =
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
      ): Result[seq[RLeafSpecs],HexaryError] =
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
    proof: seq[SnapProof];    ## Storage slots proof data
    noBaseBoundCheck = false;  ## Ignore left boundary proof check if `true`
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [RlpError,KeyError].} =
  ## Process storage slots for a particular storage root. See `importAccounts()`
  ## for comments on the return value.
  let
    tmpDb = SnapDbBaseRef.init(ps, data.account.storageRoot.to(NodeKey))
  var
    slots: seq[RLeafSpecs]        # validated slots to add to database
    dangling: seq[NodeSpecs]      # return value
    proofStats: TrieNodeStat      # `proof` data dangling links
    innerSubTrie: seq[NodeSpecs]  # internal, collect dangling links
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
    if 0 < proof.len:
      # Inspect trie for dangling nodes. This is not a big deal here as the
      # proof data is typically small.
      let topTag = slots[^1].pathTag
      for w in proofStats.dangling:
        let iv = w.partialPath.hexaryEnvelope
        if iv.maxPt < base or topTag < iv.minPt:
          # Dangling link with partial path envelope outside accounts range
          discard
        else:
          # Overlapping partial path envelope.
          innerSubTrie.add w

    # Build partial hexary trie
    let rc = tmpDb.hexaDb.hexaryInterpolate(
      tmpDb.root, slots, bootstrap = (proof.len == 0))
    if rc.isErr:
      return err(rc.error)

    # Collect missing inner sub-trees in the reconstructed partial hexary
    # trie (if any).
    let bottomTag = slots[0].pathTag
    for w in innerSubTrie:
      if not ps.hexaDb.tab.hasKey(w.nodeKey.to(RepairKey)):
        if not noBaseBoundCheck:
          # Verify that `base` is to the left of the first slot and there is
          # nothing in between.
          #
          # Without `proof` data available there can only be a complete
          # set/list of accounts so there are no dangling nodes in the first
          # place. But there must be `proof` data for an empty list.
          if w.partialPath.hexaryEnvelope.maxPt < bottomTag:
            return err(LowerBoundProofError)
        # Otherwise register left over entry
        dangling.add w

    # Commit to main descriptor
    for k,v in tmpDb.hexaDb.tab.pairs:
      if not k.isNodeKey:
        return err(UnresolvedRepairNode)
      ps.hexaDb.tab[k] = v

  elif proof.len == 0:
    # There must be a proof for an empty argument list.
    return err(LowerBoundProofError)

  else:
    if not noBaseBoundCheck:
      for w in proofStats.dangling:
        if base <= w.partialPath.hexaryEnvelope.maxPt:
          return err(LowerBoundProofError)
    dangling = proofStats.dangling

  ok(dangling)

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
  new result
  result.init(pv, root.to(NodeKey))
  result.peer = peer
  result.accKey = accKey

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getStorageSlotsFn*(
    ps: SnapDbStorageSlotsRef;
      ): HexaryGetFn =
  ## Return `HexaryGetFn` closure.
  let getFn = ps.kvDb.persistentStorageSlotsGetFn()
  return proc(key: openArray[byte]): Blob = getFn(ps.accKey, key)

proc getStorageSlotsFn*(
    pv: SnapDbRef;
    accKey: NodeKey;
      ): HexaryGetFn =
  ## Variant of `getStorageSlotsFn()` for captured `accKey` argument.
  let getFn = pv.kvDb.persistentStorageSlotsGetFn()
  return proc(key: openArray[byte]): Blob = getFn(accKey, key)


proc importStorageSlots*(
    ps: SnapDbStorageSlotsRef; ## Re-usable session descriptor
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
    persistent = false;        ## store data on disk
    noBaseBoundCheck = false;  ## Ignore left boundary proof check if `true`
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
          data.base, data.storages[sTop], data.proof, noBaseBoundCheck)
        if rc.isErr:
          result.add HexaryNodeReport(slot: itemInx, error: rc.error)
          trace "Storage slots last item fails", peer, itemInx=sTop, nItems,
            nSlots=data.storages[sTop].data.len, proofs=data.proof.len,
            error=rc.error, nErrors=result.len
        elif 0 < rc.value.len:
          result.add HexaryNodeReport(slot: itemInx, dangling: rc.value)

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
    except IOError as e:
      result.add HexaryNodeReport(slot: itemInx, error: IOErrorException)
      error "Import storage slots exception", peer, itemInx, nItems,
        name=($e.name), msg=e.msg, nErrors=result.len

  #when extraTraceMessages:
  #  if result.len == 0:
  #    trace "Storage slots imported", peer, nItems,
  #      nSlotLists=data.storages.len, proofs=data.proof.len

proc importStorageSlots*(
    pv: SnapDbRef;             ## Base descriptor on `ChainDBRef`
    peer: Peer;                ## For log messages, only
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
    noBaseBoundCheck = false;  ## Ignore left boundary proof check if `true`
      ): seq[HexaryNodeReport] =
  ## Variant of `importStorages()`
  SnapDbStorageSlotsRef.init(
    pv,  Hash256().to(NodeKey), Hash256(), peer).importStorageSlots(
      data, persistent = true, noBaseBoundCheck)


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
  except IOError as e:
    result.add HexaryNodeReport(slot: slot, error: IOErrorException)
    nErrors.inc
    error "Import storage slots nodes exception", peer, slot, nItems,
      name=($e.name), msg=e.msg, nErrors

  when extraTraceMessages:
    if nErrors == 0:
      trace "Raw storage slots nodes imported", peer, slot, nItems,
        report=result.len

proc importRawStorageSlotsNodes*(
    pv: SnapDbRef;                ## Base descriptor on `ChainDBRef`
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
    ps: SnapDbStorageSlotsRef;           ## Re-usable session descriptor
    pathList = seq[Blob].default;        ## Starting nodes for search
    resumeCtx: TrieNodeStatCtxRef = nil; ## Context for resuming inspection
    suspendAfter = high(uint64);         ## To be resumed
    persistent = false;                  ## Read data from disk
    ignoreError = false;                 ## Always return partial results if any
      ): Result[TrieNodeStat, HexaryError] =
  ## Starting with the argument list `pathSet`, find all the non-leaf nodes in
  ## the hexary trie which have at least one node key reference missing in
  ## the trie database. Argument `pathSet` list entries that do not refer to a
  ## valid node are silently ignored.
  ##
  ## Trie inspection can be automatically suspended after having visited
  ## `suspendAfter` nodes to be resumed at the last state. An application of
  ## this feature would look like
  ## ::
  ##   var ctx = TrieNodeStatCtxRef()
  ##   while not ctx.isNil:
  ##     let rc = inspectStorageSlotsTrie(.., resumeCtx=ctx, suspendAfter=1024)
  ##     ...
  ##     ctx = rc.value.resumeCtx
  ##
  let peer {.used.} = ps.peer
  var stats: TrieNodeStat
  noExceptionOops("inspectStorageSlotsTrie()"):
    if persistent:
      stats = ps.getStorageSlotsFn.hexaryInspectTrie(
        ps.root, pathList, resumeCtx, suspendAfter=suspendAfter)
    else:
      stats = ps.hexaDb.hexaryInspectTrie(
        ps.root, pathList, resumeCtx, suspendAfter=suspendAfter)

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
    pv: SnapDbRef;                       ## Base descriptor on `ChainDBRef`
    peer: Peer;                          ## For log messages, only
    accKey: NodeKey;                     ## Account key
    root: Hash256;                       ## state root
    pathList = seq[Blob].default;        ## Starting paths for search
    resumeCtx: TrieNodeStatCtxRef = nil; ## Context for resuming inspection
    suspendAfter = high(uint64);         ## To be resumed
    ignoreError = false;                 ## Always return partial results if any
      ): Result[TrieNodeStat, HexaryError] =
  ## Variant of `inspectStorageSlotsTrieTrie()` for persistent storage.
  SnapDbStorageSlotsRef.init(
    pv, accKey, root, peer).inspectStorageSlotsTrie(
      pathList, resumeCtx, suspendAfter, persistent=true, ignoreError)


proc getStorageSlotsData*(
    ps: SnapDbStorageSlotsRef; ## Re-usable session descriptor
    path: NodeKey;             ## Account to visit
    persistent = false;        ## Read data from disk
      ): Result[Account,HexaryError] =
  ## Fetch storage slots data.
  ##
  ## Caveat: There is no unit test yet
  let peer {.used.} = ps.peer
  var acc: Account

  noExceptionOops("getStorageSlotsData()"):
    var leaf: Blob
    if persistent:
      leaf = path.hexaryPath(ps.root, ps.getStorageSlotsFn).leafData
    else:
      leaf = path.hexaryPath(ps.root, ps.hexaDb).leafData

    if leaf.len == 0:
      return err(SlotsNotFound)
    acc = rlp.decode(leaf,Account)

  return ok(acc)

proc getStorageSlotsData*(
    pv: SnapDbRef;             ## Base descriptor on `ChainDBRef`
    peer: Peer,                ## For log messages, only
    accKey: NodeKey;              ## Account key
    root: Hash256;             ## state root
    path: NodeKey;             ## Account to visit
      ): Result[Account,HexaryError] =
  ## Variant of `getStorageSlotsData()` for persistent storage.
  SnapDbStorageSlotsRef.init(
    pv, accKey, root, peer).getStorageSlotsData(path, persistent=true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
