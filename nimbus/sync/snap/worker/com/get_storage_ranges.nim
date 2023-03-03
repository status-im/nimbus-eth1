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
    leftOver*: seq[AccountSlotsHeader]
    data*: AccountStorageRange

const
  emptyBlob = seq[byte].default

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
        emptyBlob, emptyBlob,
        fetchRequestBytesLimit)
    return ok(reply)

  except CatchableError as e:
    let error {.used.} = e.msg
    trace trSnapRecvError & "waiting for GetStorageRanges reply", peer, pivot,
      error
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
  ## Fetch data using the `snap#` protocol, returns the range covered.
  ##
  ## If the first `accounts` argument sequence item has the `firstSlot` field
  ## set non-zero, only this account is fetched with a range. Otherwise all
  ## accounts are asked for without a range (non-zero `firstSlot` fields are
  ## ignored of later sequence items.)
  let
    peer {.used.} = buddy.peer
  var
    nAccounts = accounts.len

  if nAccounts == 0:
    return err(ComEmptyAccountsArguments)

  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetStorageRanges", peer, pivot, nAccounts

  let
    iv = accounts[0].subRange
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
        return err(ComTooManyStorageSlots)
      rc.value.get

  let
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
    # Empty data for a slot indicates missing data
    if snStoRanges.slotLists[n].len == 0:
      dd.leftOver.add accounts[n]
    else:
      dd.data.storages.add AccountSlots(
        account: accounts[n], # known to be no fewer accounts than slots
        data:    snStoRanges.slotLists[n])

  # Complete the part that was not answered by the peer
  if nProof == 0:
    # assigning empty slice is ok
    dd.leftOver = dd.leftOver & accounts[nSlotLists ..< nAccounts]

  else:
    # Ok, we have a proof now
    if 0 < snStoRanges.slotLists[^1].len:
      # If the storage data for the last account comes with a proof, then the
      # data set is incomplete. So record the missing part on the `dd.leftOver`
      # list.
      let
        reqTop = if accounts[0].subRange.isNone: high(NodeTag)
                 else: accounts[0].subRange.unsafeGet.maxPt
        respTop = dd.data.storages[^1].data[^1].slotHash.to(NodeTag)
      if respTop < reqTop:
        dd.leftOver.add AccountSlotsHeader(
          subRange:    some(NodeTagRange.new(respTop + 1.u256, reqTop)),
          accKey:      accounts[nSlotLists-1].accKey,
          storageRoot: accounts[nSlotLists-1].storageRoot)

    # Do thew rest (assigning empty slice is ok)
    dd.leftOver = dd.leftOver & accounts[nSlotLists ..< nAccounts]

  trace trSnapRecvReceived & "StorageRanges", peer, pivot, nAccounts,
    nSlotLists, nProof, nLeftOver=dd.leftOver.len

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
