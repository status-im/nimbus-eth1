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

import
  chronos,
  eth/[common/eth_types, p2p],
  nimcrypto/keccak,
  stew/interval_set,
  "../../.."/[protocol, protocol/trace_config, types],
  ../../path_desc,
  ../worker_desc

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

const
  snapRequestBytesLimit = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap` protocol calls.

type
  FetchError* = enum
    NothingSerious,
    MissingProof,
    AccountsMinTooSmall,
    AccountsMaxTooLarge,
    NoAccountsForStateRoot,
    NetworkProblem

  FetchAccounts* = object
    consumed*: UInt256     ## Leftmost accounts used from argument range
    data*: accountRangeObj ## reply data

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

proc fetchAccounts*(
    peer: WorkerBuddy;
    stateRoot: TrieHash;
    iv: LeafRange
      ): Future[Result[FetchAccounts,FetchError]] {.async.} =
  ## Fetch data using the `snap#` protocol, returns the range covered.
  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetAccountRange", peer,
      accRange=iv, stateRoot, bytesLimit=snapRequestBytesLimit

  var dd = block:
    let rc = await peer.getAccountRange(stateRoot, iv)
    if rc.isErr:
      return err(NetworkProblem)
    if rc.value.isNone:
      trace trSnapRecvTimeoutWaiting & "for reply to GetAccountRange", peer
      return err(NothingSerious)
    FetchAccounts(
      consumed: iv.len,
      data: rc.value.get)

  let
    nAccounts = dd.data.accounts.len
    nProof = dd.data.proof.len

  if nAccounts == 0:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#getaccountrange-0x00:
    # Notes:
    # * Nodes must always respond to the query.
    # * If the node does not have the state for the requested state root, it
    #   must return an empty reply. It is the responsibility of the caller to
    #   query an state not older than 128 blocks.
    # * The responding node is allowed to return less data than requested (own
    #   QoS limits), but the node must return at least one account. If no
    #   accounts exist between startingHash and limitHash, then the first (if
    #   any) account after limitHash must be provided.
    if nProof == 0:
      # Maybe try another peer
      trace trSnapRecvReceived & "EMPTY AccountRange reply", peer,
        nAccounts, nProof, accRange="n/a", reqRange=iv, stateRoot
      return err(NoAccountsForStateRoot)

    # So there is no data, otherwise an account beyond the interval end
    # `iv.maxPt` would have been returned.
    trace trSnapRecvReceived & "END AccountRange message", peer,
      nAccounts, nProof, accRange=LeafRange.new(iv.minPt, high(NodeTag)),
      reqRange=iv, stateRoot
    dd.consumed = high(NodeTag) - iv.minPt
    return ok(dd)

  let (accMinPt, accMaxPt) =
        (dd.data.accounts[0].accHash, dd.data.accounts[^1].accHash)

  if nProof == 0:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#accountrange-0x01
    # Notes:
    # * If the account range is the entire state (requested origin was 0x00..0
    #   and all accounts fit into the response), no proofs should be sent along
    #   the response. This is unlikely for accounts, but since it's a common
    #   situation for storage slots, this clause keeps the behavior the same
    #   across both.
    if 0.to(NodeTag) < iv.minPt:
      trace trSnapRecvProtocolViolation & "missing proof in AccountRange", peer,
        nAccounts, nProof, accRange=LeafRange.new(iv.minPt, accMaxPt),
        reqRange=iv, stateRoot
      return err(MissingProof)
    # TODO: How do I know that the full accounts list is correct?

  if accMinPt < iv.minPt:
    # Not allowed
    trace trSnapRecvProtocolViolation & "min too small in AccountRange", peer,
      nAccounts, nProof, accRange=LeafRange.new(accMinPt, accMaxPt),
      reqRange=iv, stateRoot
    return err(AccountsMinTooSmall)

  if iv.maxPt < accMaxPt:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#getaccountrange-0x00:
    # Notes:
    # * [..]
    # * [..]
    # * [..] If no accounts exist between startingHash and limitHash, then the
    #   first (if any) account after limitHash must be provided.
    if 1 < nAccounts:
      trace trSnapRecvProtocolViolation & "max too large in AccountRange", peer,
        nAccounts, nProof, accRange=LeafRange.new(iv.minPt, accMaxPt),
        reqRange=iv, stateRoot
      return err(AccountsMaxTooLarge)

  trace trSnapRecvReceived & "AccountRange message", peer,
    nAccounts, nProof, accRange=LeafRange.new(iv.minPt, accMaxPt),
    reqRange=iv, stateRoot

  dd.consumed = (accMaxPt - iv.minPt) + 1
  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
