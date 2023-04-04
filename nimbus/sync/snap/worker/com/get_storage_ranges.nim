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

{.push raises: [].}

import
  std/[options, sequtils],
  chronos,
  eth/[common, p2p],
  stew/interval_set,
  "../../.."/[protocol, protocol/trace_config],
  "../.."/[constants, range_desc, worker_desc],
  ./com_error

logScope:
  topics = "snap-fetch"

type
  # SnapStorage* = object
  #  slotHash*: Hash256
  #  slotData*: Blob
  #
  # SnapStorageRanges* = object
  #  slotLists*: seq[seq[SnapStorage]]
  #  proof*: seq[SnapProof]

  GetStorageRanges* = object
    leftOver*: seq[AccountSlotsChanged]
    data*: AccountStorageRange

const
  extraTraceMessages = false or true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getStorageRangesReq(
    buddy: SnapBuddyRef;
    root: Hash256;
    accounts: seq[Hash256];
    iv: Option[NodeTagRange];
    pivot: string;
      ): Future[Result[Option[SnapStorageRanges],void]]
      {.async.} =
  let
    peer = buddy.peer
  try:
    var reply: Option[SnapStorageRanges]

    if iv.isSome:
      reply = await peer.getStorageRanges(
        root, accounts,
        # here the interval bounds are an `array[32,byte]`
        iv.get.minPt.to(Hash256).data, iv.get.maxPt.to(Hash256).data,
        fetchRequestBytesLimit)
    else:
      reply = await peer.getStorageRanges(
        root, accounts,
        # here the interval bounds are of empty `Blob` type
        EmptyBlob, EmptyBlob,
        fetchRequestBytesLimit)
    return ok(reply)

  except CatchableError as e:
    trace trSnapRecvError & "waiting for GetStorageRanges reply", peer, pivot,
      name=($e.name), error=(e.msg)
    return err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getStorageRanges*(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;                ## Current DB base (`pivot` for logging)
    accounts: seq[AccountSlotsHeader]; ## List of per-account storage slots
    pivot: string;                     ## For logging, instead of `stateRoot`
      ): Future[Result[GetStorageRanges,ComError]]
      {.async.} =
  ## Fetch data using the `snap/1` protocol, returns the range covered.
  ##
  ## If the first `accounts` argument sequence item has the optional `subRange`
  ## field set, only this account is fetched with for the range `subRange`.
  ## Otherwise all accounts are asked for without a range (`subRange` fields
  ## are ignored for later accounts list items.)
  var nAccounts = accounts.len
  if nAccounts == 0:
    return err(ComEmptyAccountsArguments)

  let
    peer {.used.} = buddy.peer
    iv = accounts[0].subRange

  when trSnapTracePacketsOk:
    when extraTraceMessages:
      trace trSnapSendSending & "GetStorageRanges", peer, pivot, nAccounts,
        iv=iv.get(otherwise=FullNodeTagRange)
    else:
      trace trSnapSendSending & "GetStorageRanges", peer, pivot, nAccounts

  let
    snStoRanges = block:
      let rc = await buddy.getStorageRangesReq(stateRoot,
        accounts.mapIt(it.accKey.to(Hash256)), iv, pivot)
      if rc.isErr:
        return err(ComNetworkProblem)
      if rc.value.isNone:
        trace trSnapRecvTimeoutWaiting & "for StorageRanges", peer, pivot,
          nAccounts
        return err(ComResponseTimeout)
      if nAccounts < rc.value.get.slotLists.len:
        # Ooops, makes no sense
        trace trSnapRecvReceived & "too many slot lists", peer, pivot,
          nAccounts, nReceived=rc.value.get.slotLists.len
        return err(ComTooManyStorageSlots)
      rc.value.get

    nSlotLists = snStoRanges.slotLists.len
    nProof = snStoRanges.proof.nodes.len

  if nSlotLists == 0:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#getstorageranges-0x02:
    #
    # Notes:
    # * Nodes must always respond to the query.
    # * If the node does not have the state for the requested state root or
    #   for any requested account hash, it must return an empty reply. It is
    #   the responsibility of the caller to query an state not older than 128
    #   blocks; and the caller is expected to only ever query existing accounts.
    trace trSnapRecvReceived & "empty StorageRanges", peer, pivot,
      nAccounts, nSlotLists, nProof, firstAccount=accounts[0].accKey
    return err(ComNoStorageForAccounts)

  # Assemble return structure for given peer response
  var dd = GetStorageRanges(
    data: AccountStorageRange(
      proof: snStoRanges.proof.nodes))

  # Set the left proof boundary (if any)
  if 0 < nProof and iv.isSome:
    dd.data.base = iv.unsafeGet.minPt

  # Filter remaining `slots` responses:
  # * Accounts for empty ones go back to the `leftOver` list.
  for n in 0 ..< nSlotLists:
    if 0 < snStoRanges.slotLists[n].len or (n == nSlotLists-1 and 0 < nProof):
      # Storage slot data available. The last storage slots list may
      # be a proved empty sub-range.
      dd.data.storages.add AccountSlots(
        account: accounts[n], # known to be no fewer accounts than slots
        data:    snStoRanges.slotLists[n])

    else: # if n < nSlotLists-1 or nProof == 0:
      # Empty data here indicate missing data
      dd.leftOver.add AccountSlotsChanged(
        account: accounts[n])

  if 0 < nProof:
    # Ok, we have a proof now. In that case, there is always a duplicate
    # of the proved entry on the  `dd.leftOver` list.
    #
    # Note that `storages[^1]` exists due to the clause
    # `(n==nSlotLists-1 and 0<nProof)` in the above `for` loop.
    let topAcc = dd.data.storages[^1].account
    dd.leftOver.add AccountSlotsChanged(account: topAcc)
    if 0 < dd.data.storages[^1].data.len:
      let
        reqMaxPt = topAcc.subRange.get(otherwise = FullNodeTagRange).maxPt
        respMaxPt = dd.data.storages[^1].data[^1].slotHash.to(NodeTag)
      if respMaxPt < reqMaxPt:
        dd.leftOver[^1].newRange = some(
          NodeTagRange.new(respMaxPt + 1.u256, reqMaxPt))
  elif 0 < dd.data.storages.len:
    let topAcc = dd.data.storages[^1].account
    if topAcc.subRange.isSome:
      #
      # Fringe case when a partial request was answered without a proof.
      # This means, that the interval requested covers the complete trie.
      #
      # Copying the request to the `leftOver`, the ranges reflect the new
      # state: `topAcc.subRange.isSome` and `newRange.isNone`.
      dd.leftOver.add AccountSlotsChanged(account: topAcc)

  # Complete the part that was not answered by the peer.
  dd.leftOver = dd.leftOver & accounts[nSlotLists ..< nAccounts].mapIt(
    AccountSlotsChanged(account: it))

  when trSnapTracePacketsOk:
    trace trSnapRecvReceived & "StorageRanges", peer, pivot, nAccounts,
      nSlotLists, nProof, nSlotLstRc=dd.data.storages.len,
      nLeftOver=dd.leftOver.len

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
