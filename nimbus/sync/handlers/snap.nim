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
  std/[sequtils, strutils],
  chronicles,
  chronos,
  eth/[common, p2p, trie/nibbles],
  stew/[byteutils, interval_set],
  ../../db/db_chain,
  ../../core/chain,
  ../snap/[constants, range_desc],
  ../snap/worker/db/[hexary_desc, hexary_error, hexary_paths,
                     snapdb_persistent, hexary_range],
  ../protocol,
  ../protocol/snap/snap_types

import
  std/[hashes, options, tables],
  ../snap/worker/db/[hexary_debug, snapdb_debug]

logScope:
  topics = "snap-wire"

type
  DebugStateRef = ref object   # <--- will go away (debugging)
    nStripped: int             # <--- will go away (debugging)
    gaps: NodeTagRangeSet      # <--- will go away (debugging)
    nBatchMin: int             # <--- will go away (debugging)
    nStripOff: int             # <--- will go away (debugging)
    stripOffMax: int           # <--- will go away (debugging)
    slotsOk: bool              # <--- will go away (debugging)

  SnapWireRef* = ref object of SnapWireBase
    chain: ChainRef
    elaFetchMax: chronos.Duration
    dataSizeMax: int
    peerPool: PeerPool

    dbgTab: TableRef[NodeKey,DebugStateRef] # <--- will go away (debugging)
    dbgSlotsStripped: int                   # <--- will go away (debugging)

  SlotsSpecs = object
    slotFn: HexaryGetFn                 # For accessing storage slots
    stoRoot: NodeKey                    # Storage root

const
  extraTraceMessages = false or true
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

  samAccHash = Hash256
   .fromHex("15848580460fe989f91c1d3ff44f03945f6378961a2fbc5829ab4cbbbc1a375c")
   #.default

  defaultAccountBatchSizeMin = 30
  defaultAccountStripOff = 2
  defaultAccountMaxStripOff = 10

  defaultSlotsBatchSizeMin = 50
  defaultSlotsStripOff = 2
  defaultSlotsMaxStripOff = 10

  yPartPaths = @[
    # @[0x00u8, 0x53u8, 0x9du8],
    # @[0x00u8, 0x53u8, 0x9eu8],
    # @[0x00u8, 0x53u8, 0x9fu8],
    EmptyBlob]

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
  let db = ctx.chain.com.db.db
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
  let db = ctx.chain.com.db.db
  return proc(key: openArray[byte]): Blob =
    db.get(key)

proc getCodeFn(
    ctx: SnapWireRef;
      ): HexaryGetFn
      {.gcsafe.} =
  # It is save to borrow this function from the snap sync implementation.
  ctx.chain.com.db.db.persistentContractsGetFn

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
# Debugging
# ------------------------------------------------------------------------------

proc gapSpecs(
    ctx: SnapWireRef;                   # Handler descriptor
    rootKey: NodeKey;                   # State root
    slotsOk: bool;
      ): DebugStateRef
      {.discardable,gcsafe, raises: [KeyError].} =
  if not ctx.dbgTab.isNil:
    if ctx.dbgTab.hasKey(rootKey):
      return ctx.dbgTab[rootkey]
    if slotsOk:
      result = DebugStateRef(
        gaps:        NodeTagRangeSet.init(),
        nBatchMin:   defaultSlotsBatchSizeMin,
        stripOffMax: defaultSlotsMaxStripOff - ctx.dbgSlotsStripped,
        nStripOff:   defaultSlotsStripOff,
        slotsOk:     true)
    else:
      result = DebugStateRef(
        gaps:        NodeTagRangeSet.init(),
        nBatchMin:   defaultAccountBatchSizeMin,
        stripOffMax: defaultAccountMaxStripOff,
        nStripOff:   defaultAccountStripOff,
        slotsOk:     false)
    ctx.dbgTab[rootkey] = result

proc mindTheGap(
    ctx: SnapWireRef;                   # Handler descriptor
    rootKey: NodeKey;                   # State root
    iv: NodeTagRange;
    slotsOk = false;
      ): Result[NodeTagRange,void]
      {.gcsafe, raises: [KeyError].} =
  ## Chop off registered ranges from argument interval `iv`
  let p = ctx.gapSpecs(rootKey, slotsOk)
  if not p.isNil:
    let
      nGaps = p.gaps.chunks
      nStripped = p.nStripped
      nStripOff = p.nStripOff
    if 0 < p.gaps.covered(iv.minPt,iv.minPt):
      trace logTxt "mindTheGap, left gap => reject", slotsOk, nGaps,
        nStripped, nStripOff, rootKey
      return err()

    let rc = p.gaps.ge iv.minPt
    if rc.isOk and rc.value.minPt < iv.maxPt:
      trace logTxt "mindTheGap, right end gap => chop", slotsOk, nGaps,
        nStripped, nStripOff, rootKey
      return ok(NodeTagRange.new(iv.minPt, rc.value.minPt - 1.u256))

    trace logTxt "mindTheGap, unrestricted", slotsOk, nGaps, nStripped

  ok(iv)

proc chopTail(
    ctx: SnapWireRef;                   # Handler descriptor
    rootKey: NodeKey;                   # State root
    getFn: HexaryGetFn;                 # Database abstraction
    rng: RangeProof;
    p: DebugStateRef;
      ): RangeProof
      {.gcsafe, raises: [CatchableError].} =
  ## Strip off tail from a proof result
  if not ctx.dbgTab.isNil and ctx.dbgTab.hasKey(rootKey):
    let p = ctx.dbgTab[rootKey]
    if p.nStripped < p.stripOffMax and
       p.nBatchMin <= rng.leafs.len and
       p.nStripOff < rng.leafs.len:

      p.nStripped += p.nStripOff
      if p.slotsOk:
        ctx.dbgSlotsStripped.inc p.nStripOff

      let
        left = rng.leafs[^(p.nStripOff+1)].key.to(NodeTag)+1.u256
        right = rng.leafs[^1].key.to(NodeTag)
      discard p.gaps.merge(left,right)

      var chopped = rng
      # chopped.leafsLast = false # <-- produces error
      chopped.leafs.setLen(rng.leafs.len - p.nStripOff)

      trace logTxt "chopTail", slotsOk=p.slotsOk, nStripOff=p.nStripOff,
        nOrigTail=rng.leafs.len, nModifiedTail=chopped.leafs.len,
        nGaps=p.gaps.chunks, nStripped=p.nStripped, nBatchMin=p.nBatchMin,
        rootKey

      return getFn.hexaryRangeLeafsProof(rootKey, chopped)

    elif p.gaps.chunks == 0:
      ctx.dbgTab.del(rootKey)

  rng


proc dumpDb(
    ctx: SnapWireRef;                   # Handler descriptor
    getFn: HexaryGetFn;                 # Database abstraction
    rootKey: NodeKey;
    info: string;
    limit = 1000;
      ): HexaryTreeDbRef
      {.discardable, gcsafe, raises: [CatchableError].} =
  result = HexaryTreeDbRef.init()
  var (nLeafs, nNodes) = (-1,-1)
  let rc = result.fromPersistent(rootKey, getFn, limit)
  if rc.isOk:
    nLeafs = rc.value
    nNodes = result.tab.len
  else:
    let dbg = HexaryTreeDbRef.init()
    let rx = dbg.fromPersistent(rootKey, getFn, limit + 100000)
    if rx.isOk:
      nLeafs = rx.value
      nNodes = dbg.tab.len
    result = HexaryTreeDbRef.init() # override
    let hlf = limit div 2
    discard result.fromPersistent(rootKey, getFn, hlf)
    discard result.fromPersistent(rootKey, getFn, limit - hlf, reverse=true)

  result.assignPrettyKeys(rootKey)
  debug logTxt "dumpDb", info, nLeafs, nNodes, rootKey,
    dump=result.pp(rootKey, "|")

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
      # -------------------------------------------------
      # when extraTraceMessages:
      #   trace logTxt "doTrieNodeSpecs", rootKey, accPath=w.accPath.toHex
      # -------------------------------------------------
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
    dbg = HexaryTreeDbRef(nil);
    lossy = DebugStateRef(nil);
    slotsOk = false;
      ): Result[RangeProof,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Generic leaf fetcher
  # ---------------------------------------
  let (iv, isChopped) = block:                  # <--- will go away (debugging)
    let rc = ctx.mindTheGap(rootKey,iv,slotsOk) # <--- will go away (debugging)
    if rc.isErr:                                # <--- will go away (debugging)
      return err(HexaryError(0))                # <--- will go away (debugging)
    let jv = rc.value                           # <--- will go away (debugging)
    (jv, jv.maxPt != iv.maxPt)                  # <--- will go away (debugging)
  # ---------------------------------------

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
    # ---------------------------------------
    if not isChopped:                           # <--- will go away
      return ok(ctx.chopTail(                   # <--- will go away
        rootKey, getFn, rc.value, lossy))       # <--- will go away
    # ---------------------------------------
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

  ctx.dbgTab = newTable[NodeKey,DebugStateRef]() # <--- will go away (debugging)

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
        let rc = ctx.fetchLeafRange(
          sp.slotFn, sp.stoRoot, iv, sizeLeft, stopAt, slotsOk=true)
        if rc.isErr:
          when extraTraceMessages:
            trace logTxt "getStorageRanges: failed", iv, sizeMax, sizeLeft,
              accKey=accHash.to(NodeKey), stoRoot=sp.stoRoot,
              nDbgSlotStripped=ctx.dbgSlotsStripped, error=rc.error
          return # extraction failed
        rc.value


    # Process data slots for this account
    dataAllocated += rangeProof.leafsSize

    when extraTraceMessages:
      trace logTxt "getStorageRanges: data slots", iv, sizeMax, dataAllocated,
        nAccounts=accounts.len, accKey=accHash.to(NodeKey), stoRoot=sp.stoRoot,
        nSlots=rangeProof.leafs.len, nProof=rangeProof.proof.len,
        nDbgSlotStripped=ctx.dbgSlotsStripped

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
        let data = steps.path[^1].node.convertTo(Blob)
        # ----------------------------------------------
        when extraTraceMessages:
          for w in yPartPaths:
            if partPath == w:
              logPartPath.add partPath
              break
        doAssert steps.path[^1].key == data.digestTo(NodeKey).to(Blob)
        # ----------------------------------------------
        data
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

  # ----------------------------------------------
  when extraTraceMessages:
    if 0 < logPartPath.len:
      let
        dbg = HexaryTreeDbRef.init()
        getFn = ctx.getAccountFn
      dbg.assignPrettyKeys(rootKey)
      for partPath in logPartPath:
        let
          steps = partPath.hexPrefixDecode[1].hexaryPath(rootKey, getFn)
          fKey = block:
            if steps.path.len == 0 or steps.path[^1].node.kind != Branch: "ø"
            else: steps.path[^1].node.bLink[15].toHex
        trace logTxt "getTrieNodes: dump", partPath=partPath.toHex,
          steps=steps.path[^1].key.toHex, fKey, steps=steps.pp(dbg,"|"),
          keys=steps.path.mapIt(it.key.toHex).join("|")
  # ----------------------------------------------

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
