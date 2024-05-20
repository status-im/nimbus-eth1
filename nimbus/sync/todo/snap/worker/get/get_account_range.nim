# Nimbus
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

{.push raises: [].}

import
  std/sequtils,
  chronos,
  eth/[common, p2p],
  stew/interval_set,
  "../../.."/[protocol, protocol/trace_config],
  "../.."/[constants, range_desc, worker_desc],
  ./get_error

logScope:
  topics = "snap-get"

type
  GetAccountRange* = object
    data*: PackedAccountRange             ## Re-packed reply data
    withStorage*: seq[AccountSlotsHeader] ## Accounts with storage root
    withContract*: seq[AccountCodeHeader]  ## Accounts with contacts

const
  extraTraceMessages = false # or true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getAccountRangeReq(
    buddy: SnapBuddyRef;
    root: Hash256;
    iv: NodeTagRange;
    pivot: string;
      ): Future[Result[Option[SnapAccountRange],void]] {.async.} =
  let
    peer = buddy.peer
  try:
    let reply = await peer.getAccountRange(
      root, iv.minPt.to(Hash256).data, iv.maxPt.to(Hash256).data,
      fetchRequestBytesLimit)
    return ok(reply)
  except CatchableError as e:
    when trSnapTracePacketsOk:
      trace trSnapRecvError & "waiting for GetAccountRange reply", peer, pivot,
        error=(e.msg)
    return err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getAccountRange*(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;         ## Current DB base (see `pivot` for logging)
    iv: NodeTagRange;           ## Range to be fetched
    pivot: string;              ## For logging, instead of `stateRoot`
      ): Future[Result[GetAccountRange,GetError]] {.async.} =
  ## Fetch data using the `snap#` protocol, returns the range covered.
  let
    peer {.used.} = buddy.peer
  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetAccountRange", peer, pivot, accRange=iv

  let snAccRange = block:
    let rc = await buddy.getAccountRangeReq(stateRoot, iv, pivot)
    if rc.isErr:
      return err(GetNetworkProblem)
    if rc.value.isNone:
      when trSnapTracePacketsOk:
        trace trSnapRecvTimeoutWaiting & "for AccountRange", peer, pivot
      return err(GetResponseTimeout)
    rc.value.get

  var dd = GetAccountRange(
    data: PackedAccountRange(
      proof:    snAccRange.proof.nodes,
      accounts: snAccRange.accounts
        # Re-pack accounts data
        .mapIt(PackedAccount(
          accKey:  it.accHash.to(NodeKey),
          accBlob: it.accBody.encode))))

  # Collect accounts with non-empty storage or contract code
  for w in snAccRange.accounts:
    if w.accBody.storageRoot != EMPTY_ROOT_HASH:
      # Collect accounts with non-empty storage
      dd.withStorage.add AccountSlotsHeader(
        accKey:      w.accHash.to(NodeKey),
        storageRoot: w.accBody.storageRoot)
    if w.accBody.codeHash != EMPTY_CODE_HASH:
      # Collect accounts with contract data
      dd.withContract.add AccountCodeHeader(
        accKey:      w.accHash.to(NodeKey),
        codeHash:    w.accBody.codeHash)

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
      when trSnapTracePacketsOk:
        trace trSnapRecvReceived & "empty AccountRange", peer, pivot,
          nAccounts, nProof, accRange="n/a", reqRange=iv
      return err(GetNoAccountsForStateRoot)

    # So there is no data and a proof.
    when trSnapTracePacketsOk:
      trace trSnapRecvReceived & "terminal AccountRange", peer, pivot,
        nAccounts, nProof, accRange=NodeTagRange.new(iv.minPt, high(NodeTag)),
        reqRange=iv
    return ok(dd)

  let (accMinPt, accMaxPt) = (
    dd.data.accounts[0].accKey.to(NodeTag),
    dd.data.accounts[^1].accKey.to(NodeTag))

  if accMinPt < iv.minPt:
    # Not allowed
    when trSnapTracePacketsOk:
      trace trSnapRecvProtocolViolation & "min too small in AccountRange", peer,
        pivot, nAccounts, nProof, accRange=NodeTagRange.new(accMinPt, accMaxPt),
        reqRange=iv
    return err(GetAccountsMinTooSmall)

  if iv.maxPt < accMaxPt:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#getaccountrange-0x00:
    # Notes:
    # * [..]
    # * [..]
    # * [..] If no accounts exist between startingHash and limitHash, then the
    #   first (if any) account after limitHash must be provided.
    if 1 < nAccounts:
      # Geth always seems to allow the last account to be larger than the
      # limit (seen with Geth/v1.10.18-unstable-4b309c70-20220517.)
      if iv.maxPt < dd.data.accounts[^2].accKey.to(NodeTag):
        # The second largest should not excceed the top one requested.
        when extraTraceMessages:
          when trSnapTracePacketsOk:
            trace trSnapRecvProtocolViolation & "AccountRange top exceeded",
              peer, pivot, nAccounts, nProof,
              accRange=NodeTagRange.new(iv.minPt, accMaxPt), reqRange=iv
        return err(GetAccountsMaxTooLarge)

  when trSnapTracePacketsOk:
    trace trSnapRecvReceived & "AccountRange", peer, pivot, nAccounts, nProof,
      accRange=NodeTagRange.new(accMinPt, accMaxPt), reqRange=iv

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
