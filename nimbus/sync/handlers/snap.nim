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
  eth/[p2p, trie/trie_defs],
  stew/[byteutils, interval_set],
  ../../db/db_chain,
  ../../core/chain,
  ../snap/[constants, range_desc],
  ../snap/worker/db/[hexary_desc, hexary_error, hexary_paths, hexary_range],
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

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

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
    chain: ChainRef;
      ): HexaryGetFn
      {.gcsafe.} =
  let db = chain.com.db.db
  return proc(key: openArray[byte]): Blob =
    db.get(key)

proc getStoSlotFn(
    chain: ChainRef;
    accKey: NodeKey;
      ): HexaryGetFn
      {.gcsafe.} =
  let db = chain.com.db.db
  return proc(key: openArray[byte]): Blob =
    db.get(key)

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

proc mkNodeTagRange(
    origin: openArray[byte];
    limit: openArray[byte];
    nAccounts = 1;
      ): Result[NodeTagRange,void] =
  var (minPt, maxPt) = (low(NodeTag), high(NodeTag))

  if 0 < origin.len or 0 < limit.len:

    # Range applies only if there is exactly one account. A number of accounts
    # different from 1 may be used by `getStorageRanges()`
    if nAccounts == 0:
      return err() # oops: no account

    # Veriify range atguments
    if not minPt.init(origin) or not maxPt.init(limit) or maxPt <= minPt:
      when extraTraceMessages:
        trace logTxt "mkNodeTagRange: malformed range", origin, limit
      return err()

    if 1 < nAccounts:
      return ok(NodeTagRange.new(low(NodeTag), high(NodeTag)))

  ok(NodeTagRange.new(minPt, maxPt))


proc fetchLeafRange(
    ctx: SnapWireRef;                   # Handler descriptor
    getFn: HexaryGetFn;                 # Database abstraction
    root: Hash256;                      # State root
    iv: NodeTagRange;                   # Proofed range of leaf paths
    replySizeMax: int;                  # Updated size counter for the raw list
    stopAt: Moment;                     # Implies timeout
      ): Result[RangeProof,HexaryError]
      {.gcsafe, raises: [CatchableError].} =

  # Assemble result Note that the size limit is the size of the leaf nodes
  # on wire. So the `sizeMax` is the argument size `replySizeMax` with some
  # space removed to accomodate for the proof nodes.
  let
    rootKey = root.to(NodeKey)
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
    iv = block: # Calculate effective accounts range (if any)
      let rc = origin.mkNodeTagRange limit
      if rc.isErr:
        return # malformed interval
      rc.value

    db = ctx.chain.getAccountFn
    stopAt = Moment.now() + ctx.elaFetchMax
    rc = ctx.fetchLeafRange(db, root, iv, sizeMax, stopAt)

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

    accGetFn = ctx.chain.getAccountFn
    rootKey = root.to(NodeKey)
    stopAt = Moment.now() + ctx.elaFetchMax

  # Loop over accounts
  var
    dataAllocated = 0
    timeExceeded = false
    slotLists: seq[seq[SnapStorage]]
    proof: seq[SnapProof]
  for accHash in accounts:
    let
      accKey = accHash.to(NodeKey)
      accData = accKey.hexaryPath(rootKey, accGetFn).leafData

    # Ignore missing account entry
    if accData.len == 0:
      slotLists.add emptySnapStorageList
      dataAllocated.inc # empty list
      when extraTraceMessages:
        trace logTxt "getStorageRanges: no data", iv, sizeMax, dataAllocated,
          accDataLen=accData.len
      continue

    # Ignore empty storage list
    let stoRoot = rlp.decode(accData,Account).storageRoot
    if stoRoot == emptyRlpHash:
      slotLists.add emptySnapStorageList
      dataAllocated.inc # empty list
      trace logTxt "getStorageRanges: no slots", iv, sizeMax, dataAllocated,
        accDataLen=accData.len, stoRoot
      continue

    # Stop unless there is enough space left
    if sizeMax - dataAllocated <= estimatedProofSize:
      break

    # Prepare for data collection
    let
      slotsGetFn = ctx.chain.getStoSlotFn(accKey)
      sizeLeft = sizeMax - dataAllocated

    # Collect data slots for this account
    let rc = ctx.fetchLeafRange(slotsGetFn, stoRoot, iv, sizeLeft, stopAt)
    if rc.isErr:
      when extraTraceMessages:
        trace logTxt "getStorageRanges: failed", iv, sizeMax, sizeLeft,
          accDataLen=accData.len, stoRoot, error=rc.error
      return # extraction failed

    # Process data slots for this account
    dataAllocated += rc.value.leafsSize

    when extraTraceMessages:
      if accounts.len == 1:
        trace logTxt "getStorageRanges: single account", iv, accKey, stoRoot

    #trace logTxt "getStorageRanges: data slots", iv, sizeMax, dataAllocated,
    #  accKey, stoRoot, nSlots=rc.value.leafs.len, nProof=rc.value.proof.len

    slotLists.add rc.value.leafs.mapIt(it.to(SnapStorage))
    if 0 < rc.value.proof.len:
      proof = rc.value.proof
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
      {.gcsafe.} =
  notImplemented("getByteCodes")

method getTrieNodes*(
    ctx: SnapWireRef;
    root: Hash256;
    paths: openArray[SnapTriePaths];
    replySizeMax: uint64;
      ): seq[Blob]
      {.gcsafe.} =
  notImplemented("getTrieNodes")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
