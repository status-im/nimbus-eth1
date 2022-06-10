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

import
  std/sets,
  chronos,
  eth/[common/eth_types, p2p],
  nimcrypto/keccak,
  ../../../../utils/interval_set,
  "../../.."/[protocol, protocol/trace_config, types],
  ../../path_desc,
  ".."/[ticker, worker_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap fetch"

const
  snapRequestBytesLimit = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap` protocol calls.

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getAccountRange(
    sp: WorkerBuddy;
    root: TrieHash;
    iv: LeafRange
      ): Future[Result[Option[accountRangeObj],void]] {.async.} =
  try:
    let reply = await sp.peer.getAccountRange(
      root.to(Hash256), iv.minPt, iv.maxPt, snapRequestBytesLimit)
    return ok(reply)

  except CatchableError as e:
    trace trSnapRecvError & "waiting for reply to GetAccountRange", peer=sp,
      error=e.msg
    return err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchSnap*(
    peer: WorkerBuddy;
    stateRoot: TrieHash;
    iv: LeafRange
      ): Future[Result[LeafRange,void]] {.async.} =
  ## Fetch data using the `snap#` protocol, returns the unused left-over range
  ## from `iv` (error return result means empty interval in that context.)
  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetAccountRange", peer,
      accRange=iv, stateRoot, bytesLimit=snapRequestBytesLimit

  let reply = block:
    let rc = await peer.getAccountRange(stateRoot, iv)
    if rc.isErr:
      inc peer.stats.major.networkErrors
      peer.ctrl.stopped = true
      return ok(iv)
    if rc.value.isNone:
      trace trSnapRecvTimeoutWaiting & "for reply to GetAccountRange", peer
      return ok(iv)
    rc.value.get

  let
    accounts = reply.accounts
    nAccounts = accounts.len

    # TODO: We're not currently verifying boundary proofs, but we do depend on
    # whether there is a proof supplied.  Unlike Snap sync, the Pie sync
    # algorithm doesn't verify most boundary proofs at this stage.
    proof = reply.proof
    nProof = proof.len

  if nAccounts == 0:
    # If there's no proof, this reply means the peer has no accounts available
    # in the range for this query.  But if there's a proof, this reply means
    # there are no more accounts starting at path `origin` up to max path.
    # This makes all the difference to terminating the fetch.  For now we'll
    # trust the mere existence of the proof rather than verifying it.
    if nProof == 0:
      trace trSnapRecvReceived & "EMPTY AccountRange message", peer,
        nAccounts, nProof, accRange="n/a", reqRange=iv, stateRoot
      # Don't keep retrying snap for this state.
      peer.ctrl.stopRequest = true
      return ok(iv)
    else:
      let accRange = LeafRange.new(iv.minPt, high(LeafItem))
      trace trSnapRecvReceived & "END AccountRange message", peer,
        nAccounts, nProof, accRange, reqRange=iv, stateRoot
      # Current slicer can't accept more result data than was requested, so
      # just leave the requested slice claimed and update statistics.
      return err()

  let accRange = LeafRange.new(iv.minPt, accounts[^1].accHash)
  trace trSnapRecvReceived & "AccountRange message", peer,
    accounts=accounts.len, proofs=proof.len, accRange,
    reqRange=iv, stateRoot

  # Missing proof isn't allowed, unless `minPt` is min path in which case
  # there might be no proof if the result spans the entire range.
  if proof.len == 0 and iv.minPt != low(LeafItem):
    trace trSnapRecvProtocolViolation & "missing proof in AccountRange", peer,
      nAccounts, nProof, accRange, reqRange=iv, stateRoot
    return ok(iv)

  if accRange.maxPt < iv.maxPt:
    peer.tickerCountAccounts(0, nAccounts)
    return ok(LeafRange.new(accRange.maxPt + 1.u256, iv.maxPt))

  var keepAccounts = nAccounts
  # Current slicer can't accept more result data than was requested.
  # So truncate to limit before updating statistics.
  while iv.maxPt < accounts[keepAccounts-1].accHash:
    dec keepAccounts
    if keepAccounts == 0:
      break

  peer.tickerCountAccounts(0, keepAccounts)
  return err() # all of `iv` used

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
