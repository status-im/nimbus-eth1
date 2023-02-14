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
  chronicles,
  chronos,
  eth/p2p,
  ../protocol,
  ../protocol/snap/snap_types,
  ../../core/chain

logScope:
  topics = "wire-protocol"

type
  SnapWireRef* = ref object of SnapWireBase
    chain: ChainRef
    peerPool: PeerPool

const
  transportAccountSizeMax = 110
    ## Account record with `high(UInt256)` hashes and balance, and maximal
    ## nonce within RLP list

  transportProofNodeSizeMax = 536
    ## Branch node with all branches `high(UInt256)` within RLP list

# ------------------------------------------------------------------------------
# Private functions: helper functions
# ------------------------------------------------------------------------------

proc notImplemented(name: string) =
  debug "snapWire: hHandler method not implemented", meth=name

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

proc accountRangeSize*(n: int): int =
  ## Max number of bytes needed to store `n` RLP encoded `Account()` type
  ## entries. Note that this is an *approximate* upper bound.
  ##
  ## The maximum size of a single RLP encoded account item can be determined
  ## by setting every field of `Account()` to `high()` or `0xff`.
  ##
  ## Note: Public function subject to unit tests
  # Experimentally derived, see `test_calc` unit test module
  if 595 < n:
    4 + n * transportAccountSizeMax
  elif 2 < n:
    3 + n * transportAccountSizeMax
  elif 0 < n:
    2 + n * transportAccountSizeMax
  else:
    1

proc proofNodesSize*(n: int): int =
  ## Ditto for proof nodes
  ##
  ## Note: Public function subject to unit tests
  # Experimentally derived, see `test_calc` unit test module
  if 125 < n:
    4 + n * transportProofNodeSizeMax
  elif 0 < n:
    3 + n * transportProofNodeSizeMax
  else:
    1

proc accountRangeNumEntries*(size: int): int =
  ## Number of entries with size guaranteed to not exceed the argument `size`.
  if transportAccountSizeMax + 3 <= size:
    result = (size - 3) div transportAccountSizeMax

# ------------------------------------------------------------------------------
# Public functions: snap wire protocol handlers
# ------------------------------------------------------------------------------

method getAccountRange*(
    ctx: SnapWireRef;
    root: Hash256;
    origin: Hash256;
    limit: Hash256;
    replySizeMax: uint64;
      ): (seq[SnapAccount], SnapAccountProof)
      {.gcsafe.} =
  notImplemented("getAccountRange")

method getStorageRanges*(
    ctx: SnapWireRef;
    root: Hash256;
    accounts: openArray[Hash256];
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): (seq[seq[SnapStorage]], SnapStorageProof)
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
