# Nimbus - Fetch account and storage states from peers by snapshot traversal
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module fetches the Ethereum account state trie from network peers by
## traversing leaves of the trie in leaf path order, making network requests
## using the `snap` protocol.
##
## From the leaves it is possible to reconstruct parts of a full trie.  With a
## separate trie traversal process it is possible to efficiently update the
## leaf states for related tries (new blocks), and merge partial data from
## different related tries (blocks at different times) together in a way that
## eventually becomes a full trie for a single block.

{.push raises: [Defect].}

import
  std/[sets, tables, algorithm, random, sequtils],
  chronos, stint, nimcrypto/keccak,
  eth/[common/eth_types, rlp, p2p],
  "."/[sync_types, pie_common, protocol_snap1]

const
  snapRequestBytesLimit = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap` protocol calls.

proc snapFetch*(sp: SyncPeer, stateRoot: TrieHash,
                leafRange: LeafRange) {.async.} =
  var origin = leafRange.leafLow
  var limit = leafRange.leafHigh
  const responseBytes = 2 * 1024 * 1024

  if sp.stopped:
    traceNetworkError "<< Peer already disconnected, not sending snap.GetAccountRange (0x00)",
      accountRange=pathRange(origin, limit),
      stateRoot=($stateRoot), bytesLimit=snapRequestBytesLimit, peer=sp
    sp.putSlice(leafRange)

  if tracePackets:
    tracePacket ">> Sending snap.GetAccountRange (0x00)",
      accountRange=pathRange(origin, limit),
      stateRoot=($stateRoot), bytesLimit=snapRequestBytesLimit, peer=sp

  var reply: typeof await sp.peer.getAccountRange(stateRoot, origin, limit,
                                                  snapRequestBytesLimit)
  try:
    reply = await sp.peer.getAccountRange(stateRoot, origin, limit,
                                          snapRequestBytesLimit)
  except CatchableError as e:
    traceNetworkError "<< Error waiting for reply to snap.GetAccountRange (0x00)",
      error=e.msg, peer=sp
    inc sp.stats.major.networkErrors
    sp.stopped = true
    sp.putSlice(leafRange)
    return

  if reply.isNone:
    traceTimeout "<< Timeout waiting for reply to snap.GetAccountRange (0x00)",
      peer=sp
    sp.putSlice(leafRange)
    return

  # TODO: Unwanted copying here caused by `.get`.  But the simple alternative
  # where `reply.get` is used on every access, even just to get `.len`, results
  # in more copying.  TODO: Check if this `let` should be `var`.
  let accountsAndProof = reply.get
  template accounts: auto = accountsAndProof.accounts
  # TODO: We're not currently verifying boundary proofs, but we do depend on
  # whether there is a proof supplied.  Unlike Snap sync, the Pie sync
  # algorithm doesn't verify most boundary proofs at this stage.
  template proof: auto = accountsAndProof.proof

  let len = accounts.len
  if len == 0:
    # If there's no proof, this reply means the peer has no accounts available
    # in the range for this query.  But if there's a proof, this reply means
    # there are no more accounts starting at path `origin` up to max path.
    # This makes all the difference to terminating the fetch.  For now we'll
    # trust the mere existence of the proof rather than verifying it.
    if proof.len == 0:
      tracePacket "<< Got EMPTY reply snap.AccountRange (0x01)",
        got=len, proofLen=proof.len, gotRange="-",
        requestedRange=pathRange(origin, limit), stateRoot=($stateRoot), peer=sp
      sp.putSlice(leafRange)
      # Don't keep retrying snap for this state.
      sp.stopThisState = true
    else:
      tracePacket "<< Got END reply snap.AccountRange (0x01)",
        got=len, proofLen=proof.len, gotRange=pathRange(origin, high(LeafPath)),
        requestedRange=pathRange(origin, limit), stateRoot=($stateRoot), peer=sp
      # Current slicer can't accept more result data than was requested, so
      # just leave the requested slice claimed and update statistics.
      sp.countSlice(origin, limit, true)
    return

  var lastPath = accounts[len-1].accHash
  tracePacket "<< Got reply snap.AccountRange (0x01)",
    got=len, proofLen=proof.len, gotRange=pathRange(origin, lastPath),
    requestedRange=pathRange(origin, limit), stateRoot=($stateRoot), peer=sp

  # Missing proof isn't allowed, unless `origin` is min path in which case
  # there might be no proof if the result spans the entire range.
  if proof.len == 0 and origin != low(LeafPath):
    tracePacketError "<< Protocol violation, missing proof in snap.AccountRange (0x01)",
      got=len, proofLen=proof.len, gotRange=pathRange(origin, lastPath),
      requestedRange=pathRange(origin, limit), stateRoot=($stateRoot), peer=sp
    sp.putSlice(leafRange)
    return

  var keepAccounts = len
  if lastPath < limit:
    sp.countSlice(origin, lastPath, true)
    sp.putSlice(lastPath + 1, limit)
  else:
    # Current slicer can't accept more result data than was requested.
    # So truncate to limit before updating statistics.
    sp.countSlice(origin, limit, true)
    while lastPath > limit:
      dec keepAccounts
      if keepAccounts == 0:
        break
      lastPath = accounts[keepAccounts-1].accHash

  sp.countAccounts(keepAccounts)

proc peerSupportsSnap*(sp: SyncPeer): bool {.inline.} =
  not sp.stopped and sp.peer.supports(snap1)
