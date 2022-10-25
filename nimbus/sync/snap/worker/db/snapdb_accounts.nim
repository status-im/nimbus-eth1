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
  std/[algorithm, sequtils, strutils, tables],
  chronicles,
  eth/[common, p2p, rlp, trie/nibbles],
  stew/byteutils,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_import, hexary_interpolate,
       hexary_inspect, hexary_paths, snapdb_desc, snapdb_persistent]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

type
  SnapDbAccountsRef* = ref object of SnapDbBaseRef
    peer: Peer               ## For log messages
    getClsFn: AccountsGetFn  ## Persistent database `get()` closure

const
  extraTraceMessages = false or true

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(h: Hash256; T: type NodeKey): T =
  h.data.T

proc convertTo(data: openArray[byte]; T: type Hash256): T =
  discard result.data.NodeKey.init(data) # size error => zero

proc getFn(ps: SnapDbAccountsRef): HexaryGetFn =
  ## Derive from `GetClsFn` closure => `HexaryGetFn`. There reason for that
  ## seemingly redundant mapping is that here is space for additional localised
  ## and locked parameters as done with the `StorageSlotsGetFn`.
  return proc(key: openArray[byte]): Blob = ps.getClsFn(key)

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
# Private functions
# ------------------------------------------------------------------------------

proc persistentAccounts(
    db: HexaryTreeDbRef;      ## Current table
    ps: SnapDbAccountsRef;    ## For persistent database
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,OSError,KeyError].} =
  ## Store accounts trie table on databse
  if ps.rockDb.isNil:
    let rc = db.persistentAccountsPut(ps.kvDb)
    if rc.isErr: return rc
  else:
    let rc = db.persistentAccountsPut(ps.rockDb)
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

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapDbAccountsRef;
    pv: SnapDbRef;
    root: Hash256;
    peer: Peer = nil
      ): T =
  ## Constructor, starts a new accounts session.
  let db = pv.kvDb
  new result
  result.init(pv, root.to(NodeKey))
  result.peer = peer
  result.getClsFn = db.persistentAccountsGetFn()

proc dup*(
    ps: SnapDbAccountsRef;
    root: Hash256;
    peer: Peer;
      ): SnapDbAccountsRef =
  ## Resume an accounts session with different `root` key and `peer`.
  new result
  result[].shallowCopy(ps[])
  result.root = root.to(NodeKey)
  result.peer = peer

proc dup*(
    ps: SnapDbAccountsRef;
    root: Hash256;
      ): SnapDbAccountsRef =
  ## Variant of `dup()` without the `peer` argument.
  new result
  result[].shallowCopy(ps[])
  result.root = root.to(NodeKey)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc importAccounts*(
    ps: SnapDbAccountsRef;    ## Re-usable session descriptor
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
      let rc = ps.mergeProofs(ps.peer, ps.root, data.proof)
      if rc.isErr:
        return err(rc.error)
    block:
      let rc = ps.peer.collectAccounts(base, data.accounts)
      if rc.isErr:
        return err(rc.error)
      accounts = rc.value
    block:
      let rc = ps.hexaDb.hexaryInterpolate(
        ps.root, accounts, bootstrap = (data.proof.len == 0))
      if rc.isErr:
        return err(rc.error)

    if persistent and 0 < ps.hexaDb.tab.len:
      let rc = ps.hexaDb.persistentAccounts(ps)
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
      root=ps.root.ByteArray32.toHex,
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
  SnapDbAccountsRef.init(
    pv, root, peer).importAccounts(base, data, persistent=true)


proc importRawAccountsNodes*(
    ps: SnapDbAccountsRef;       ## Re-usable session descriptor
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
    for n,rec in nodes:
      if 0 < rec.data.len: # otherwise ignore empty placeholder
        slot = some(n)
        var rep = db.hexaryImport(rec)
        if rep.error != NothingSerious:
          rep.slot = slot
          result.add rep
          nErrors.inc
          trace "Error importing account nodes", peer, inx=n, nItems,
            error=rep.error, nErrors
        elif rep.kind.isSome and rep.kind.unsafeGet in reportNodes:
          rep.slot = slot
          result.add rep

    # Store to disk
    if persistent and 0 < db.tab.len:
      slot = none(int)
      let rc = db.persistentAccounts(ps)
      if rc.isErr:
        result.add HexaryNodeReport(slot: slot, error: rc.error)

  except RlpError:
    result.add HexaryNodeReport(slot: slot, error: RlpEncoding)
    nErrors.inc
    trace "Error importing account nodes", peer, slot, nItems,
      error=RlpEncoding, nErrors
  except KeyError as e:
    raiseAssert "Not possible @ importRawAccountNodes: " & e.msg
  except OSError as e:
    result.add HexaryNodeReport(slot: slot, error: OSErrorException)
    nErrors.inc
    trace "Import account nodes exception", peer, slot, nItems,
      name=($e.name), msg=e.msg, nErrors

  when extraTraceMessages:
    if nErrors == 0:
      trace "Raw account nodes imported", peer, slot, nItems, report=result.len

proc importRawAccountsNodes*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer,                   ## For log messages, only
    nodes: openArray[NodeSpecs];  ## List of `(key,data)` records
    reportNodes = {Leaf};         ## Additional node types to report
      ): seq[HexaryNodeReport] =
  ## Variant of `importRawNodes()` for persistent storage.
  SnapDbAccountsRef.init(
    pv, Hash256(), peer).importRawAccountsNodes(
      nodes, reportNodes, persistent=true)


proc inspectAccountsTrie*(
    ps: SnapDbAccountsRef;        ## Re-usable session descriptor
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
  noRlpExceptionOops("inspectAccountsTrie()"):
    if persistent:
      stats = ps.getFn.hexaryInspectTrie(ps.root, pathList)
    else:
      stats = ps.hexaDb.hexaryInspectTrie(ps.root, pathList)

  block checkForError:
    var error = TrieIsEmpty
    if stats.stopped:
      error = TrieLoopAlert
      trace "Inspect account trie failed", peer, nPathList=pathList.len,
        nDangling=stats.dangling.len, stoppedAt=stats.level, error
    elif 0 < stats.level:
      break checkForError
    if ignoreError:
      return ok(stats)
    return err(error)

  #when extraTraceMessages:
  #  trace "Inspect account trie ok", peer, nPathList=pathList.len,
  #    nDangling=stats.dangling.len, level=stats.level

  return ok(stats)

proc inspectAccountsTrie*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer;                   ## For log messages, only
    root: Hash256;                ## state root
    pathList = seq[Blob].default; ## Starting paths for search
    ignoreError = false;          ## Always return partial results when avail.
      ): Result[TrieNodeStat, HexaryDbError] =
  ## Variant of `inspectAccountsTrie()` for persistent storage.
  SnapDbAccountsRef.init(
    pv, root, peer).inspectAccountsTrie(pathList, persistent=true, ignoreError)


proc getAccountsNodeKey*(
    ps: SnapDbAccountsRef;        ## Re-usable session descriptor
    path: Blob;                   ## Partial node path
    persistent = false;           ## Read data from disk
      ): Result[NodeKey,HexaryDbError] =
  ## For a partial node path argument `path`, return the raw node key.
  var rc: Result[NodeKey,void]
  noRlpExceptionOops("getAccountsNodeKey()"):
    if persistent:
      rc = ps.getFn.hexaryInspectPath(ps.root, path)
    else:
      rc = ps.hexaDb.hexaryInspectPath(ps.root, path)
  if rc.isOk:
    return ok(rc.value)
  err(NodeNotFound)

proc getAccountsNodeKey*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer;                   ## For log messages, only
    root: Hash256;                ## state root
    path: Blob;                   ## Partial node path
      ): Result[NodeKey,HexaryDbError] =
  ## Variant of `getAccountsNodeKey()` for persistent storage.
  SnapDbAccountsRef.init(
    pv, root, peer).getAccountsNodeKey(path, persistent=true)


proc getAccountsData*(
    ps: SnapDbAccountsRef;        ## Re-usable session descriptor
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
      leaf = path.hexaryPath(ps.root, ps.getFn).leafData
    else:
      leaf = path.hexaryPath(ps.root.to(RepairKey),ps.hexaDb).leafData

    if leaf.len == 0:
      return err(AccountNotFound)
    acc = rlp.decode(leaf,Account)

  return ok(acc)

proc getAccountsData*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    peer: Peer;                   ## For log messages, only
    root: Hash256;                ## State root
    path: NodeKey;                ## Account to visit
      ): Result[Account,HexaryDbError] =
  ## Variant of `getAccountsData()` for persistent storage.
  SnapDbAccountsRef.init(
    pv, root, peer).getAccountsData(path, persistent=true)

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

proc getAccountsChainDb*(
    ps: SnapDbAccountsRef;
    accHash: Hash256;
      ): Result[Account,HexaryDbError] =
  ## Fetch account via `BaseChainDB`
  ps.getAccountsData(accHash.to(NodeKey),persistent=true)

proc nextAccountsChainDbKey*(
    ps: SnapDbAccountsRef;
    accHash: Hash256;
      ): Result[Hash256,HexaryDbError] =
  ## Fetch the account path on the `BaseChainDB`, the one next to the
  ## argument account key.
  noRlpExceptionOops("getChainDbAccount()"):
    let path = accHash.to(NodeKey)
                      .hexaryPath(ps.root, ps.getFn)
                      .next(ps.getFn)
                      .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256))

  err(AccountNotFound)

proc prevAccountsChainDbKey*(
    ps: SnapDbAccountsRef;
    accHash: Hash256;
      ): Result[Hash256,HexaryDbError] =
  ## Fetch the account path on the `BaseChainDB`, the one before to the
  ## argument account.
  noRlpExceptionOops("getChainDbAccount()"):
    let path = accHash.to(NodeKey)
                      .hexaryPath(ps.root, ps.getFn)
                      .prev(ps.getFn)
                      .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256))

  err(AccountNotFound)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
