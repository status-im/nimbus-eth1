# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  chronicles,
  chronos,
  eth/[common, p2p, trie/db, trie/nibbles],
  stew/[byteutils, interval_set],
  ../../core/chain,
  ../../db/core_db/legacy,
  ../snap/[constants, range_desc],
  ../snap/worker/db/[hexary_desc, hexary_error, hexary_paths,
                     snapdb_persistent, hexary_range],
  ../protocol,
  ../protocol/snap/snap_types

logScope:
  topics = "snap-wire"

type
  SnapWireRef* = ref object of SnapWireBase
    chain: ChainRef
    elaFetchMax: chronos.Duration
    dataSizeMax: int
    peerPool: PeerPool

  SlotsSpecs = object
    slotFn: HexaryGetFn                 # For accessing storage slots
    stoRoot: NodeKey                    # Storage root

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

  estimatedNodeSize = hexaryRangeRlpNodesListSizeMax(1)
    ## Some expected upper limit for a single node

  estimatedProofSize = hexaryRangeRlpNodesListSizeMax(10)
    ## Some expected upper limit, typically not mote than 10 proof nodes

  emptySnapStorageList = seq[SnapStorage].default
    ## Dummy list for empty slots

  defaultElaFetchMax = 990.milliseconds
    ## Fetching accounts or slots can be extensive, stop in the middle if
    ## it takes too long

  defaultDataSizeMax = fetchRequestBytesLimit
    ## Truncate maximum data size

# ------------------------------------------------------------------------------
# Private functions: helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "handlers.snap." & info

proc notImplemented(name: string) {.used.} =
  debug "Wire handler method not implemented", meth=name

# ----------------------------------

proc getAccountFn(
    ctx: SnapWireRef;
      ): HexaryGetFn
      {.gcsafe.} =
  # The snap sync implementation provides a function `persistentAccountGetFn()`
  # similar to this one. But it is not safe to use it at the moment as the
  # storage table might (or might not) differ.
  let db = ctx.chain.com.db.toLegacyTrieRef
  return proc(key: openArray[byte]): Blob =
    db.get(key)

proc getStoSlotFn(
    ctx: SnapWireRef;
    accKey: NodeKey;
      ): HexaryGetFn
      {.gcsafe.} =
  # The snap sync implementation provides a function
  # `persistentStorageSlotsGetFn()` similar to this one. But it is not safe to
  # use it at the moment as the storage table might (or might not) differ.
  let db = ctx.chain.com.db.toLegacyTrieRef
  return proc(key: openArray[byte]): Blob =
    db.get(key)

proc getCodeFn(
    ctx: SnapWireRef;
      ): HexaryGetFn
      {.gcsafe.} =
  # It is save to borrow this function from the snap sync implementation.
  ctx.chain.com.db.persistentContractsGetFn

# ----------------------------------

proc to(
    rl: RangeLeaf;
    T: type SnapAccount;
      ): T
      {.gcsafe, raises: [RlpError].} =
  ## Convert the generic `RangeLeaf` argument to payload type.
  T(accHash: rl.key.to(Hash256),
    accBody: rl.data.decode(Account))

proc to(
    rl: RangeLeaf;
    T: type SnapStorage;
      ): T
      {.gcsafe.} =
  ## Convert the generic `RangeLeaf` argument to payload type.
  T(slotHash: rl.key.to(Hash256),
    slotData: rl.data)

# ------------------------------------------------------------------------------
# Private functions: fetch leaf range
# ------------------------------------------------------------------------------

proc getSlotsSpecs(
    ctx: SnapWireRef;                   # Handler descriptor
    rootKey: NodeKey;                   # State root
    accGetFn: HexaryGetFn;              # Database abstraction
    accKey: NodeKey;                    # Current account
      ): Result[SlotsSpecs,void]
      {.gcsafe, raises: [CatchableError].} =
  ## Retrieve storage slots specs from account data
  let accData = accKey.hexaryPath(rootKey, accGetFn).leafData

  # Ignore missing account entry
  if accData.len == 0:
    when extraTraceMessages:
      trace logTxt "getSlotsSpecs: no such account", accKey, rootKey
    return err()

  # Ignore empty storage list
  let stoRoot = rlp.decode(accData,Account).storageRoot
  if stoRoot == EMPTY_ROOT_HASH:
    when extraTraceMessages:
      trace logTxt "getSlotsSpecs: no slots", accKey
    return err()

  ok(SlotsSpecs(
    slotFn:  ctx.getStoSlotFn(accKey),
    stoRoot: stoRoot.to(NodeKey)))


iterator doTrieNodeSpecs(
    ctx: SnapWireRef;                   # Handler descriptor
    rootKey: NodeKey;                   # State root
    pGroups: openArray[SnapTriePaths];  # Group of partial paths
      ): (NodeKey, HexaryGetFn, Blob, int)
      {.gcsafe, raises: [CatchableError].} =
  ## Helper for `getTrieNodes()` to cycle over `pathGroups`
  let accGetFn = ctx.getAccountFn

  for w in pGroups:
    # Special case: fetch account node
    if w.slotPaths.len == 0:
      yield (rootKey, accGetFn, w.accPath, 0)
      continue

    # Compile account key
    var accKey: NodeKey
    if accKey.init(w.accPath):
      # Derive slot specs from accounts
      let rc = ctx.getSlotsSpecs(rootKey, accGetFn, accKey)
      if rc.isOk:
        # Loop over slot paths
        for path in w.slotPaths:
          when extraTraceMessages:
            trace logTxt "doTrieNodeSpecs",
              rootKey=rc.value.stoRoot, slotPath=path.toHex
          yield (rc.value.stoRoot, rc.value.slotFn, path, w.slotPaths.len)
        continue

    # Fail on this group
    when extraTraceMessages:
      trace logTxt "doTrieNodeSpecs (blind)", accPath=w.accPath.toHex,
        nBlind=w.slotPaths.len, nBlind0=w.slotPaths[0].toHex
    yield (NodeKey.default, nil, EmptyBlob, w.slotPaths.len)


proc mkNodeTagRange(
    origin: openArray[byte];
    limit: openArray[byte];
    nAccounts = 1;
      ): Result[NodeTagRange,void] =
  ## Verify and convert range arguments to interval
  var (minPt, maxPt) = (low(NodeTag), high(NodeTag))

  if 0 < origin.len or 0 < limit.len:

    # Range applies only if there is exactly one account. A number of accounts
    # different from 1 may be used by `getStorageRanges()`
    if nAccounts == 0:
      return err() # oops: no account

    # Verify range arguments
    if not minPt.init(origin) or not maxPt.init(limit) or maxPt < minPt:
      when extraTraceMessages:
        trace logTxt "mkNodeTagRange: malformed range",
          origin=origin.toHex, limit=limit.toHex
      return err()

    if 1 < nAccounts:
      return ok(NodeTagRange.new(low(NodeTag), high(NodeTag)))

  ok(NodeTagRange.new(minPt, maxPt))


proc fetchLeafRange(
    ctx: SnapWireRef;                   # Handler descriptor
    getFn: HexaryGetFn;                 # Database abstraction
    rootKey: NodeKey;                   # State root
    iv: NodeTagRange;                   # Proofed range of leaf paths
    replySizeMax: int;                  # Updated size counter for the raw list
    stopAt: Moment;                     # Implies timeout
      ): Result[RangeProof,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Generic leaf fetcher
  let
    sizeMax = replySizeMax - estimatedProofSize
    now = Moment.now()
    timeout = if now < stopAt: stopAt - now else: 1.milliseconds
    rc = getFn.hexaryRangeLeafsProof(rootKey, iv, sizeMax, timeout)
  if rc.isErr:
    error logTxt "fetchLeafRange: database problem",
      iv, replySizeMax, error=rc.error
    return rc # database error

  let sizeOnWire = rc.value.leafsSize + rc.value.proofSize
  if sizeOnWire <= replySizeMax:
    return rc

  # Estimate the overhead size on wire needed for a single leaf tail item
  const leafExtraSize = (sizeof RangeLeaf()) - (sizeof newSeq[Blob](0))

  let nLeafs = rc.value.leafs.len
  when extraTraceMessages:
    trace logTxt "fetchLeafRange: reducing reply sample",
      iv, sizeOnWire, replySizeMax, nLeafs

  # Strip parts of leafs result and amend remainder by adding proof nodes
  var (tailSize, tailItems, reduceBy) = (0, 0, replySizeMax - sizeOnWire)
  while tailSize <= reduceBy:
    tailItems.inc
    if nLeafs <= tailItems:
      when extraTraceMessages:
        trace logTxt "fetchLeafRange: stripping leaf list failed",
          iv, replySizeMax, nLeafs, tailItems
      return err(DataSizeError) # empty tail (package size too small)
    tailSize += rc.value.leafs[^tailItems].data.len + leafExtraSize

  # Provide truncated leafs list
  let
    leafProof = getFn.hexaryRangeLeafsProof(
      rootKey, RangeProof(leafs: rc.value.leafs[0 ..< nLeafs - tailItems]))
    strippedSizeOnWire = leafProof.leafsSize + leafProof.proofSize
  if strippedSizeOnWire <= replySizeMax:
    return ok(leafProof)

  when extraTraceMessages:
    trace logTxt "fetchLeafRange: data size problem",
      iv, replySizeMax, nLeafs, tailItems, strippedSizeOnWire

  err(DataSizeError)

# ------------------------------------------------------------------------------
# Private functions: peer observer
# ------------------------------------------------------------------------------

#proc onPeerConnected(ctx: SnapWireRef, peer: Peer) =
#  debug "snapWire: add peer", peer
#  discard
#
#proc onPeerDisconnected(ctx: SnapWireRef, peer: Peer) =
#  debug "snapWire: remove peer", peer
#  discard
#
#proc setupPeerObserver(ctx: SnapWireRef) =
#  var po = PeerObserver(
#    onPeerConnected:
#      proc(p: Peer) {.gcsafe.} =
#        ctx.onPeerConnected(p),
#    onPeerDisconnected:
#      proc(p: Peer) {.gcsafe.} =
#        ctx.onPeerDisconnected(p))
#  po.setProtocol protocol.snap
#  ctx.peerPool.addObserver(ctx, po)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapWireRef;
    chain: ChainRef;
    peerPool: PeerPool;
      ): T =
  ## Constructor (uses `init()` as suggested in style guide.)
  let ctx = T(
    chain:       chain,
    elaFetchMax: defaultElaFetchMax,
    dataSizeMax: defaultDataSizeMax,
    peerPool:    peerPool)

  #ctx.setupPeerObserver()
  ctx

# ------------------------------------------------------------------------------
# Public functions: helpers
# ------------------------------------------------------------------------------

proc proofEncode*(proof: seq[SnapProof]): Blob =
  var writer = initRlpWriter()
  writer.snapAppend SnapProofNodes(nodes: proof)
  writer.finish

proc proofDecode*(data: Blob): seq[SnapProof] {.gcsafe, raises: [RlpError].} =
  var reader = data.rlpFromBytes
  reader.snapRead(SnapProofNodes).nodes

# ------------------------------------------------------------------------------
# Public functions: snap wire protocol handlers
# ------------------------------------------------------------------------------

method getAccountRange*(
    ctx: SnapWireRef;
    root: Hash256;
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): (seq[SnapAccount], SnapProofNodes)
      {.gcsafe, raises: [CatchableError].} =
  ## Fetch accounts list from database
  let sizeMax = min(replySizeMax, ctx.dataSizeMax.uint64).int
  if sizeMax <= estimatedProofSize:
    when extraTraceMessages:
      trace logTxt "getAccountRange: max data size too small",
        origin=origin.toHex, limit=limit.toHex, sizeMax
    return # package size too small

  let
    rootKey = root.to(NodeKey)
    iv = block: # Calculate effective accounts range (if any)
      let rc = origin.mkNodeTagRange limit
      if rc.isErr:
        return # malformed interval
      rc.value

    stopAt = Moment.now() + ctx.elaFetchMax
    rc = ctx.fetchLeafRange(ctx.getAccountFn, rootKey, iv, sizeMax, stopAt)

  if rc.isErr:
    return # extraction failed
  let
    accounts = rc.value.leafs.mapIt(it.to(SnapAccount))
    proof = rc.value.proof

  #when extraTraceMessages:
  #  trace logTxt "getAccountRange: done", iv, replySizeMax,
  #    nAccounts=accounts.len, nProof=proof.len

  (accounts, SnapProofNodes(nodes: proof))


method getStorageRanges*(
    ctx: SnapWireRef;
    root: Hash256;
    accounts: openArray[Hash256];
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): (seq[seq[SnapStorage]], SnapProofNodes)
      {.gcsafe, raises: [CatchableError].} =
  ## Fetch storage slots list from database
  let sizeMax = min(replySizeMax, ctx.dataSizeMax.uint64).int
  if sizeMax <= estimatedProofSize:
    when extraTraceMessages:
      trace logTxt "getStorageRanges: max data size too small",
        origin=origin.toHex, limit=limit.toHex, sizeMax
    return # package size too small

  let
    iv = block: # Calculate effective slots range (if any)
      let rc = origin.mkNodeTagRange(limit, accounts.len)
      if rc.isErr:
        return # malformed interval
      rc.value

    rootKey = root.to(NodeKey)
    accGetFn = ctx.getAccountFn
    stopAt = Moment.now() + ctx.elaFetchMax

  # Loop over accounts
  var
    dataAllocated = 0
    timeExceeded = false
    slotLists: seq[seq[SnapStorage]]
    proof: seq[SnapProof]
  for accHash in accounts:
    let sp = block:
      let rc = ctx.getSlotsSpecs(rootKey, accGetFn, accHash.to(NodeKey))
      if rc.isErr:
        slotLists.add emptySnapStorageList
        dataAllocated.inc # empty list
        continue
      rc.value

    # Collect data slots for this account => `rangeProof`
    let
      sizeLeft = sizeMax - dataAllocated
      rangeProof = block:
        let rc = ctx.fetchLeafRange(sp.slotFn, sp.stoRoot, iv, sizeLeft, stopAt)
        if rc.isErr:
          when extraTraceMessages:
            trace logTxt "getStorageRanges: failed", iv, sizeMax, sizeLeft,
              accKey=accHash.to(NodeKey), stoRoot=sp.stoRoot, error=rc.error
          return # extraction failed
        rc.value

    # Process data slots for this account
    dataAllocated += rangeProof.leafsSize

    when extraTraceMessages:
      trace logTxt "getStorageRanges: data slots", iv, sizeMax, dataAllocated,
        nAccounts=accounts.len, accKey=accHash.to(NodeKey), stoRoot=sp.stoRoot,
        nSlots=rangeProof.leafs.len, nProof=rangeProof.proof.len

    slotLists.add rangeProof.leafs.mapIt(it.to(SnapStorage))
    if 0 < rangeProof.proof.len:
      proof = rangeProof.proof
      break # only last entry has a proof

    # Stop unless there is enough space left
    if sizeMax - dataAllocated <= estimatedProofSize:
      break

    if stopAt <= Moment.now():
      timeExceeded = true
      break

  when extraTraceMessages:
    trace logTxt "getStorageRanges: done", iv, sizeMax, dataAllocated,
      nAccounts=accounts.len, nLeafLists=slotLists.len, nProof=proof.len,
      timeExceeded

  (slotLists, SnapProofNodes(nodes: proof))


method getByteCodes*(
    ctx: SnapWireRef;
    nodes: openArray[Hash256];
    replySizeMax: uint64;
      ): seq[Blob]
      {.gcsafe, raises: [CatchableError].} =
  ## Fetch contract codes from  the database
  let
    sizeMax = min(replySizeMax, ctx.dataSizeMax.uint64).int
    pfxMax = (hexaryRangeRlpSize sizeMax) - sizeMax # RLP list/blob pfx max
    effSizeMax = sizeMax - pfxMax
    stopAt = Moment.now() + ctx.elaFetchMax
    getFn = ctx.getCodeFn

  var
    dataAllocated = 0
    timeExceeded = false

  when extraTraceMessages:
    trace logTxt "getByteCodes", sizeMax, nNodes=nodes.len

  for w in nodes:
    let data = w.data.toSeq.getFn
    if 0 < data.len:
      let effDataLen = hexaryRangeRlpSize data.len
      if effSizeMax - effDataLen < dataAllocated:
        break
      dataAllocated += effDataLen
      result.add data
    else:
      when extraTraceMessages:
        trace logTxt "getByteCodes: empty record", sizeMax, nNodes=nodes.len,
           key=w
    if stopAt <= Moment.now():
      timeExceeded = true
      break

  when extraTraceMessages:
    trace logTxt "getByteCodes: done", sizeMax, dataAllocated,
      nNodes=nodes.len, nResult=result.len, timeExceeded


method getTrieNodes*(
    ctx: SnapWireRef;
    root: Hash256;
    pathGroups: openArray[SnapTriePaths];
    replySizeMax: uint64;
      ): seq[Blob]
      {.gcsafe, raises: [CatchableError].} =
  ## Fetch nodes from the database
  let
    sizeMax = min(replySizeMax, ctx.dataSizeMax.uint64).int
    someSlack = sizeMax.hexaryRangeRlpSize() - sizeMax
  if sizeMax <= someSlack:
    when extraTraceMessages:
      trace logTxt "getTrieNodes: max data size too small",
        root=root.to(NodeKey), nPathGroups=pathGroups.len, sizeMax, someSlack
    return # package size too small
  let
    rootKey = root.to(NodeKey)
    effSizeMax = sizeMax - someSlack
    stopAt = Moment.now() + ctx.elaFetchMax
  var
    dataAllocated = 0
    timeExceeded = false
    logPartPath: seq[Blob]

  for (stateKey,getFn,partPath,n) in ctx.doTrieNodeSpecs(rootKey, pathGroups):
    # Special case: no data available
    if getFn.isNil:
      if effSizeMax < dataAllocated + n:
        break # no need to add trailing empty nodes
      result &= EmptyBlob.repeat(n)
      dataAllocated += n
      continue

    # Fetch node blob
    let node = block:
      let steps = partPath.hexPrefixDecode[1].hexaryPath(stateKey, getFn)
      if 0 < steps.path.len and
         steps.tail.len == 0 and steps.path[^1].nibble < 0:
        steps.path[^1].node.convertTo(Blob)
      else:
        EmptyBlob

    if effSizeMax < dataAllocated + node.len:
      break
    if stopAt <= Moment.now():
      timeExceeded = true
      break
    result &= node

  when extraTraceMessages:
    trace logTxt "getTrieNodes: done", sizeMax, dataAllocated,
      nGroups=pathGroups.mapIt(max(1,it.slotPaths.len)).foldl(a+b,0),
      nPaths=pathGroups.len, nResult=result.len, timeExceeded

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
