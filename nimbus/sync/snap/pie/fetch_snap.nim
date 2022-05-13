# Nimbus - Fetch account and storage states from peers by snapshot traversal
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

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
  std/sets,
  chronos,
  eth/[common/eth_types, p2p],
  nimcrypto/keccak,
  stint,
  "../.."/[protocol, protocol/pickeled_snap_tracers, trace_helper],
  ".."/[base_desc, path_desc, types],
  "."/[common, peer_desc]

const
  snapRequestBytesLimit = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap` protocol calls.

proc snapFetch*(sp: SnapPeerEx, stateRoot: TrieHash, leafRange: LeafRange)
    {.async.} =
  var origin = leafRange.leafLow
  var limit = leafRange.leafHigh
  const responseBytes = 2 * 1024 * 1024

  if sp.stopped:
    traceRecvError "peer already disconnected, not sending GetAccountRange",
      peer=sp, accountRange=pathRange(origin, limit),
      stateRoot=($stateRoot), bytesLimit=snapRequestBytesLimit
    sp.putSlice(leafRange)

  if tracePackets:
    traceSendSending "GetAccountRange",
      accountRange=pathRange(origin, limit),
      stateRoot=($stateRoot), bytesLimit=snapRequestBytesLimit, peer=sp

  var
    reply: Option[accountRangeObj]
  try:
    reply = await sp.peer.getAccountRange(
      stateRoot.untie, origin, limit, snapRequestBytesLimit)
  except CatchableError as e:
    traceRecvError "waiting for reply to GetAccountRange",
      peer=sp, error=e.msg
    inc sp.stats.major.networkErrors
    sp.stopped = true
    sp.putSlice(leafRange)
    return

  if reply.isNone:
    traceRecvTimeoutWaiting "for reply to GetAccountRange",
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
      traceRecvGot "EMPTY reply AccountRange", peer=sp,
        got=len, proofLen=proof.len, gotRange="-",
        requestedRange=pathRange(origin, limit), stateRoot=($stateRoot)
      sp.putSlice(leafRange)
      # Don't keep retrying snap for this state.
      sp.stopThisState = true
    else:
      traceRecvGot "END reply AccountRange", peer=sp,
        got=len, proofLen=proof.len, gotRange=pathRange(origin, high(LeafPath)),
        requestedRange=pathRange(origin, limit), stateRoot=($stateRoot)
      # Current slicer can't accept more result data than was requested, so
      # just leave the requested slice claimed and update statistics.
      sp.countSlice(origin, limit, true)
    return

  var lastPath = accounts[len-1].accHash
  traceRecvGot "reply AccountRange", peer=sp,
    got=len, proofLen=proof.len, gotRange=pathRange(origin, lastPath),
    requestedRange=pathRange(origin, limit), stateRoot=($stateRoot)

  # Missing proof isn't allowed, unless `origin` is min path in which case
  # there might be no proof if the result spans the entire range.
  if proof.len == 0 and origin != low(LeafPath):
    traceRecvProtocolViolation "missing proof in AccountRange",
      peer=sp, got=len, proofLen=proof.len, gotRange=pathRange(origin,lastPath),
      requestedRange=pathRange(origin, limit), stateRoot=($stateRoot)
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

proc peerSupportsSnap*(sp: SnapPeerEx): bool =
  not sp.stopped and sp.peer.supports(snap)
