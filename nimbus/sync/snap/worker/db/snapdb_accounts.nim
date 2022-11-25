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
  std/[algorithm, sequtils, tables],
  chronicles,
  eth/[common, p2p, rlp, trie/nibbles],
  stew/[byteutils, interval_set],
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_import, hexary_interpolate,
       hexary_inspect, hexary_paths, snapdb_desc, snapdb_persistent]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

type
  SnapDbAccountsRef* = ref object of SnapDbBaseRef
    peer: Peer               ## For log messages

  SnapAccountsGaps* = object
    innerGaps*: seq[NodeSpecs]
    dangling*: seq[NodeSpecs]

const
  extraTraceMessages = false or true

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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

  if 0 < acc.len:
    let pathTag0 = acc[0].accKey.to(NodeTag)

    # Verify lower bound
    if pathTag0 < base:
      let error = LowerBoundAfterFirstEntry
      trace "collectAccounts()", peer, base, accounts=acc.len, error
      return err(error)

    # Add first account
    rcAcc.add RLeafSpecs(pathTag: pathTag0, payload: acc[0].accBlob)

    # Veify & add other accounts
    for n in 1 ..< acc.len:
      let nodeTag = acc[n].accKey.to(NodeTag)

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
  new result
  result.init(pv, root.to(NodeKey))
  result.peer = peer

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

proc getAccountFn*(ps: SnapDbAccountsRef): HexaryGetFn =
  ## Return `HexaryGetFn` closure.
  let getFn = ps.kvDb.persistentAccountsGetFn()
  return proc(key: openArray[byte]): Blob = getFn(key)

proc getAccountFn*(pv: SnapDbRef): HexaryGetFn =
  ## Variant of `getAccountFn()`
  let getFn = pv.kvDb.persistentAccountsGetFn()
  return proc(key: openArray[byte]): Blob = getFn(key)


proc nodeExists*(
    ps: SnapDbAccountsRef;    ## Re-usable session descriptor
    node: NodeSpecs;          ## Node specs, e.g. returned by `importAccounts()`
    persistent = false;       ## Whether to check data on disk
      ): bool =
  ## ..
  if not persistent:
    return ps.hexaDb.tab.hasKey(node.nodeKey.to(RepairKey))
  try:
    return 0 < ps.getAccountFn()(node.nodeKey.ByteArray32).len
  except Exception as e:
    raiseAssert "Not possible @ importAccounts(" & $e.name & "):" & e.msg

proc nodeExists*(
    pv: SnapDbRef;            ## Base descriptor on `BaseChainDB`
    peer: Peer;               ## For log messages
    root: Hash256;            ## State root
    node: NodeSpecs;          ## Node specs, e.g. returned by `importAccounts()`
      ): bool =
  ## Variant of `nodeExists()` for presistent storage, only.
  SnapDbAccountsRef.init(pv, root, peer).nodeExists(node, persistent=true)


proc importAccounts*(
    ps: SnapDbAccountsRef;    ## Re-usable session descriptor
    base: NodeTag;            ## Before or at first account entry in `data`
    data: PackedAccountRange; ## Re-packed `snap/1 ` reply data
    persistent = false;       ## Store data on disk
    noBaseBoundCheck = false; ## Ignore left boundary proof check if `true`
      ): Result[SnapAccountsGaps,HexaryDbError] =
  ## Validate and import accounts (using proofs as received with the snap
  ## message `AccountRange`). This function accumulates data in a memory table
  ## which can be written to disk with the argument `persistent` set `true`.
  ## The memory table is held in the descriptor argument`ps`.
  ##
  ## On success, the function returns a list `innerGaps` of dangling node
  ## links from the argument `proof` list of nodes after the populating with
  ## accounts. The following example may illustrate the case:
  ##
  ##   Assume an accounts hexary trie
  ##   ::
  ##     |          0 1 2 3 4 5 6 7 8 9 a b c d e f     -- nibble positions
  ##     | root -> (a, .. b, ..   c, ..   d, ..    ,)   -- root branch node
  ##     |          |     |       |       |
  ##     |         ...    v       v       v
  ##     |               (x,X)   (y,Y)   (z,Z)
  ##
  ##   with `a`,`b`,`c`,`d` node hashes, `x`,`y`,`z` partial paths and account
  ##   hashes `3&x`,`7&y`,`b&z` for account values `X`,`Y`,`Z`. All other
  ##   links in the *root branch node* are assumed nil.
  ##
  ##   The passing to this function
  ##   * base: `3&x`
  ##   * data.proof: *root branch node*
  ##   * data.accounts: `(3&x,X)`, `(7&y,Y)`, `(b&z,Z)`
  ##   a partial tree can be fully constructed and boundary proofs succeed.
  ##   The return value will be an empty list.
  ##
  ##   Leaving out `(7&y,Y)` the boundary proofs still succeed but the
  ##   return value will be @[`(7&y,c)`].
  ##
  ## The left boundary proof might be omitted by passing `true` for the
  ## `noBaseBoundCheck` argument. In this case, the boundary check must be
  ## performed on the return code as
  ## * if `data.accounts` is empty, the return value must be an empty list
  ## * otherwise, all type `NodeSpecs` items `w` of the return code must
  ##   satisfy
  ##   ::
  ##     let leastAccountPath = data.accounts[0].accKey.to(NodeTag)
  ##     leastAccountPath <= w.partialPath.max(NodeKey).to(NodeTag)
  ##
  ## Besides the inner gaps, the function also returns the dangling nodes left
  ## from the `proof` list.
  ##
  ## Note that the `peer` argument is for log messages, only.
  var
    accounts: seq[RLeafSpecs]
    outside: seq[NodeSpecs]
    gaps: SnapAccountsGaps
  try:
    if 0 < data.proof.len:
      let rc = ps.mergeProofs(ps.peer, data.proof)
      if rc.isErr:
        return err(rc.error)
    block:
      let rc = ps.peer.collectAccounts(base, data.accounts)
      if rc.isErr:
        return err(rc.error)
      accounts = rc.value

    if 0 < accounts.len:
      var innerSubTrie: seq[NodeSpecs]
      if 0 < data.proof.len:
        # Inspect trie for dangling nodes. This is not a big deal here as the
        # proof data is typically small.
        let
          proofStats = ps.hexaDb.hexaryInspectTrie(ps.root, @[])
          topTag = accounts[^1].pathTag
        for w in proofStats.dangling:
          let iv = w.partialPath.pathEnvelope
          if base <= iv.maxPt and  iv.minPt <= topTag:
            # Extract dangling links which are inside the accounts range
            innerSubTrie.add w
          else:
            # Otherwise register outside links
            outside.add w

      # Build partial hexary trie
      let rc = ps.hexaDb.hexaryInterpolate(
        ps.root, accounts, bootstrap = (data.proof.len == 0))
      if rc.isErr:
        return err(rc.error)

      # Collect missing inner sub-trees in the reconstructed partial hexary
      # trie (if any).
      let bottomTag = accounts[0].pathTag
      for w in innerSubTrie:
        if ps.hexaDb.tab.hasKey(w.nodeKey.to(RepairKey)):
          continue
        # Verify that `base` is to the left of the first account and there is
        # nothing in between. Without proof, there can only be a complete
        # set/list of accounts. There must be a proof for an empty list.
        if not noBaseBoundCheck and
           w.partialPath.pathEnvelope.maxPt < bottomTag:
          return err(LowerBoundProofError)
        # Otherwise register left over entry
        gaps.innerGaps.add w

      if persistent:
        let rc = ps.hexaDb.persistentAccounts(ps)
        if rc.isErr:
          return err(rc.error)
        # Verify outer links against database
        let getFn = ps.getAccountFn
        for w in outside:
          if w.nodeKey.ByteArray32.getFn().len == 0:
            gaps.dangling.add w
      else:
        for w in outside:
          if not ps.hexaDb.tab.hasKey(w.nodeKey.to(RepairKey)):
            gaps.dangling.add w

    elif data.proof.len == 0:
      # There must be a proof for an empty argument list.
      return err(LowerBoundProofError)

  except RlpError:
    return err(RlpEncoding)
  except KeyError as e:
    raiseAssert "Not possible @ importAccounts(KeyError): " & e.msg
  except OSError as e:
    error "Import Accounts exception", peer=ps.peer, name=($e.name), msg=e.msg
    return err(OSErrorException)
  except Exception as e:
    raiseAssert "Not possible @ importAccounts(" & $e.name & "):" & e.msg

  #when extraTraceMessages:
  #  trace "Accounts imported", peer=ps.peer, root=ps.root.ByteArray32.toHex,
  #    proof=data.proof.len, base, accounts=data.accounts.len,
  #    top=accounts[^1].pathTag, innerGapsLen=gaps.innerGaps.len,
  #    danglingLen=gaps.dangling.len

  ok(gaps)

proc importAccounts*(
    pv: SnapDbRef;            ## Base descriptor on `BaseChainDB`
    peer: Peer;               ## For log messages
    root: Hash256;            ## State root
    base: NodeTag;            ## Before or at first account entry in `data`
    data: PackedAccountRange; ## Re-packed `snap/1 ` reply data
    noBaseBoundCheck = false; ## Ignore left bound proof check if `true`
      ): Result[SnapAccountsGaps,HexaryDbError] =
  ## Variant of `importAccounts()` for presistent storage, only.
  SnapDbAccountsRef.init(
    pv, root, peer).importAccounts(
      base, data, persistent=true, noBaseBoundCheck)


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
    for n,node in nodes:
      if 0 < node.data.len: # otherwise ignore empty placeholder
        slot = some(n)
        var rep = db.hexaryImport(node)
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
    error "Import account nodes exception", peer, slot, nItems,
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


proc getAccountsNodeKey*(
    ps: SnapDbAccountsRef;        ## Re-usable session descriptor
    path: Blob;                   ## Partial node path
    persistent = false;           ## Read data from disk
      ): Result[NodeKey,HexaryDbError] =
  ## For a partial node path argument `path`, return the raw node key.
  var rc: Result[NodeKey,void]
  noRlpExceptionOops("getAccountsNodeKey()"):
    if persistent:
      rc = ps.getAccountFn.hexaryInspectPath(ps.root, path)
    else:
      rc = ps.hexaDb.hexaryInspectPath(ps.root, path)
  if rc.isOk:
    return ok(rc.value)
  err(NodeNotFound)

proc getAccountsNodeKey*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    root: Hash256;                ## state root
    path: Blob;                   ## Partial node path
      ): Result[NodeKey,HexaryDbError] =
  ## Variant of `getAccountsNodeKey()` for persistent storage.
  SnapDbAccountsRef.init(
    pv, root, Peer()).getAccountsNodeKey(path, persistent=true)


proc getAccountsData*(
    ps: SnapDbAccountsRef;        ## Re-usable session descriptor
    path: NodeKey;                ## Account to visit
    persistent = false;           ## Read data from disk
      ): Result[Account,HexaryDbError] =
  ## Fetch account data.
  ##
  ## Caveat: There is no unit test yet for the non-persistent version
  var acc: Account

  noRlpExceptionOops("getAccountData()"):
    var leaf: Blob
    if persistent:
      leaf = path.hexaryPath(ps.root, ps.getAccountFn).leafData
    else:
      leaf = path.hexaryPath(ps.root.to(RepairKey),ps.hexaDb).leafData

    if leaf.len == 0:
      return err(AccountNotFound)
    acc = rlp.decode(leaf,Account)

  return ok(acc)

proc getAccountsData*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    root: Hash256;                ## State root
    path: NodeKey;                ## Account to visit
      ): Result[Account,HexaryDbError] =
  ## Variant of `getAccountsData()` for persistent storage.
  SnapDbAccountsRef.init(
    pv, root, Peer()).getAccountsData(path, persistent=true)

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
        accounts[item.accKey.to(NodeTag)] = item
    result = toSeq(accounts.keys).sorted(cmp).mapIt(accounts[it])

proc getAccountsChainDb*(
    ps: SnapDbAccountsRef;
    accKey: NodeKey;
      ): Result[Account,HexaryDbError] =
  ## Fetch account via `BaseChainDB`
  ps.getAccountsData(accKey, persistent = true)

proc nextAccountsChainDbKey*(
    ps: SnapDbAccountsRef;
    accKey: NodeKey;
      ): Result[NodeKey,HexaryDbError] =
  ## Fetch the account path on the `BaseChainDB`, the one next to the
  ## argument account key.
  noRlpExceptionOops("getChainDbAccount()"):
    let path = accKey
               .hexaryPath(ps.root, ps.getAccountFn)
               .next(ps.getAccountFn)
               .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256).to(NodeKey))

  err(AccountNotFound)

proc prevAccountsChainDbKey*(
    ps: SnapDbAccountsRef;
    accKey: NodeKey;
      ): Result[NodeKey,HexaryDbError] =
  ## Fetch the account path on the `BaseChainDB`, the one before to the
  ## argument account.
  noRlpExceptionOops("getChainDbAccount()"):
    let path = accKey
               .hexaryPath(ps.root, ps.getAccountFn)
               .prev(ps.getAccountFn)
               .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256).to(NodeKey))

  err(AccountNotFound)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
