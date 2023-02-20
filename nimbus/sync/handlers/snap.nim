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
  eth/p2p,
  stew/interval_set,
  ../../db/db_chain,
  ../../core/chain,
  ../snap/range_desc,
  ../snap/worker/db/[hexary_desc, hexary_range, snapdb_desc, snapdb_accounts],
  ../protocol,
  ../protocol/snap/snap_types

logScope:
  topics = "snap-wire"

type
  SnapWireRef* = ref object of SnapWireBase
    chain: ChainRef
    peerPool: PeerPool

const
  proofNodeSizeMax = 532
    ## Branch node with all branches `high(UInt256)` within RLP list

proc proofNodesSizeMax*(n: int): int {.gcsafe.}

# ------------------------------------------------------------------------------
# Private functions: helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "handlers.snap." & info

proc notImplemented(name: string) =
  debug "snapWire: hHandler method not implemented", meth=name

proc append(writer: var RlpWriter; t: SnapProof; node: Blob) =
  ## RLP mixin, encoding
  writer.snapAppend node

# ------------------------------------------------------------------------------
# Private functions: fetch leaf range
# ------------------------------------------------------------------------------

proc fetchLeafRange(
    ctx: SnapWireRef;                   # Handler descriptor
    db: HexaryGetFn;                    # Database abstraction
    root: Hash256;                      # State root
    iv: NodeTagRange;                   # Proofed range of leaf paths
    replySizeMax: int;                  # Updated size counter for the raw list
      ): Result[RangeProof,void]
      {.gcsafe, raises: [CatchableError].} =
  let
    rootKey = root.to(NodeKey)
    estimatedProofSize = proofNodesSizeMax(10) # some expected upper limit

  if replySizeMax <= estimatedProofSize:
    trace logTxt "fetchLeafRange(): data size too small", iv, replySizeMax
    return err() # package size too small

  # Assemble result Note that the size limit is the size of the leaf nodes
  # on wire. So the `sizeMax` is the argument size `replySizeMax` with some
  # space removed to accomodate for the proof nodes.
  let
    sizeMax =replySizeMax - estimatedProofSize
    rc = db.hexaryRangeLeafsProof(rootKey, iv, sizeMax)
  if rc.isErr:
    error logTxt "fetchLeafRange(): database problem",
      iv, replySizeMax, error=rc.error
    return err() # database error
  let sizeOnWire = rc.value.leafsSize + rc.value.proofSize
  if sizeOnWire <= replySizeMax:
    return ok(rc.value)

  # Strip parts of leafs result and amend remainder by adding proof nodes
  var
    leafs = rc.value.leafs
    leafsTop = leafs.len - 1
    tailSize = 0
    tailItems = 0
    reduceBy = replySizeMax - sizeOnWire
  while tailSize <= reduceBy and tailItems < leafsTop:
    # Estimate the size on wire needed for the tail item
    const extraSize = (sizeof RangeLeaf()) - (sizeof newSeq[Blob](0))
    tailSize += leafs[leafsTop - tailItems].data.len + extraSize
    tailItems.inc
  if leafsTop <= tailItems:
    trace logTxt "fetchLeafRange(): stripping leaf list failed",
      iv, replySizeMax,leafsTop, tailItems
    return err() # package size too small

  leafs.setLen(leafsTop - tailItems - 1) # chop off one more for slack
  let
    leafProof = db.hexaryRangeLeafsProof(rootKey, iv.minPt, leafs)
    strippedSizeOnWire = leafProof.leafsSize + leafProof.proofSize
  if strippedSizeOnWire <= replySizeMax:
    return ok(leafProof)

  trace logTxt "fetchLeafRange(): data size problem",
    iv, replySizeMax, leafsTop, tailItems, strippedSizeOnWire

  err()

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
    chain:    chain,
    peerPool: peerPool)

  #ctx.setupPeerObserver()
  ctx

# ------------------------------------------------------------------------------
# Public functions: helpers
# ------------------------------------------------------------------------------

proc proofNodesSizeMax*(n: int): int =
  ## Max number of bytes needed to store a list of `n` RLP encoded hexary
  ## nodes which is a `Branch` node where every link reference is set to
  ## `high(UInt256)`.
  const nMax = high(int) div proofNodeSizeMax
  if n <= nMax:
    hexaryRangeRlpSize(n * proofNodeSizeMax)
  else:
    high(int)

proc proofEncode*(proof: seq[SnapProof]): Blob =
  rlp.encode proof

# ------------------------------------------------------------------------------
# Public functions: snap wire protocol handlers
# ------------------------------------------------------------------------------

method getAccountRange*(
    ctx: SnapWireRef;
    root: Hash256;
    origin: Hash256;
    limit: Hash256;
    replySizeMax: uint64;
      ): (seq[SnapAccount], seq[SnapProof])
      {.gcsafe, raises: [CatchableError].} =
  ## Fetch accounts list from database
  let
    db = SnapDbRef.init(ctx.chain.com.db.db).getAccountFn
    iv = NodeTagRange.new(origin.to(NodeTag), limit.to(NodeTag))
    sizeMax = min(replySizeMax,high(int).uint64).int

  trace logTxt "getAccountRange(): request data range", iv, replySizeMax

  let rc = ctx.fetchLeafRange(db, root, iv, sizeMax)
  if rc.isOk:
    return (rc.value.leafs.mapIt(it.to(SnapAccount)), rc.value.proof)


method getStorageRanges*(
    ctx: SnapWireRef;
    root: Hash256;
    accounts: openArray[Hash256];
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): (seq[seq[SnapStorage]], seq[SnapProof])
      {.gcsafe.} =
  notImplemented("getStorageRanges")

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
    paths: openArray[seq[Blob]];
    replySizeMax: uint64;
      ): seq[Blob]
      {.gcsafe.} =
  notImplemented("getTrieNodes")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
