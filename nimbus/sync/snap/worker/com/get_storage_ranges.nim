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

import
  std/[options, sequtils],
  chronos,
  eth/[common, p2p],
  stew/interval_set,
  "../../.."/[protocol, protocol/trace_config],
  "../.."/[range_desc, worker_desc],
  ./com_error

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

type
  # SnapStorage* = object
  #  slotHash*: Hash256
  #  slotData*: Blob
  #
  # SnapStorageRanges* = object
  #  slotLists*: seq[seq[SnapStorage]]
  #  proof*: SnapStorageProof

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
    accounts: seq[Hash256],
    iv: Option[NodeTagRange]
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
        snapRequestBytesLimit)
    else:
      reply = await peer.getStorageRanges(
        root, accounts,
        # here the interval bounds are of empty `Blob` type
        emptyBlob, emptyBlob,
        snapRequestBytesLimit)
    return ok(reply)

  except CatchableError as e:
    trace trSnapRecvError & "waiting for GetStorageRanges reply", peer,
      error=e.msg
    return err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getStorageRanges*(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;
    accounts: seq[AccountSlotsHeader],
      ): Future[Result[GetStorageRanges,ComError]]
      {.async.} =
  ## Fetch data using the `snap#` protocol, returns the range covered.
  ##
  ## If the first `accounts` argument sequence item has the `firstSlot` field
  ## set non-zero, only this account is fetched with a range. Otherwise all
  ## accounts are asked for without a range (non-zero `firstSlot` fields are
  ## ignored of later sequence items.)
  let
    peer = buddy.peer
  var
    nAccounts = accounts.len

  if nAccounts == 0:
    return err(ComEmptyAccountsArguments)

  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetStorageRanges", peer,
      nAccounts, stateRoot, bytesLimit=snapRequestBytesLimit

  let snStoRanges = block:
    let rc = await buddy.getStorageRangesReq(
      stateRoot, accounts.mapIt(it.accKey.to(Hash256)), accounts[0].subRange)
    if rc.isErr:
      return err(ComNetworkProblem)
    if rc.value.isNone:
      trace trSnapRecvTimeoutWaiting & "for reply to GetStorageRanges", peer,
        nAccounts
      return err(ComResponseTimeout)
    if nAccounts < rc.value.get.slotLists.len:
      # Ooops, makes no sense
      return err(ComTooManyStorageSlots)
    rc.value.get

  let
    nSlotLists = snStoRanges.slotLists.len
    nProof = snStoRanges.proof.len

  if nSlotLists == 0:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#getstorageranges-0x02:
    #
    # Notes:
    # * Nodes must always respond to the query.
    # * If the node does not have the state for the requested state root or
    #   for any requested account hash, it must return an empty reply. It is
    #   the responsibility of the caller to query an state not older than 128
    #   blocks; and the caller is expected to only ever query existing accounts.
    trace trSnapRecvReceived & "empty StorageRanges", peer,
      nAccounts, nSlotLists, nProof, stateRoot, firstAccount=accounts[0].accKey
    return err(ComNoStorageForAccounts)

  # Assemble return structure for given peer response
  var dd = GetStorageRanges(data: AccountStorageRange(proof: snStoRanges.proof))

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

  # Ok, we have a proof now. What was it to be proved?
  elif snStoRanges.slotLists[^1].len == 0:
    return err(ComNoDataForProof) # Now way to prove an empty node set

  else:
    # If the storage data for the last account comes with a proof, then the data
    # set is incomplete. So record the missing part on the `dd.leftOver` list.
    let
      reqTop = if accounts[0].subRange.isNone: high(NodeTag)
               else: accounts[0].subRange.unsafeGet.maxPt
      respTop = dd.data.storages[^1].data[^1].slotHash.to(NodeTag)
    if respTop < reqTop:
      dd.leftOver.add AccountSlotsHeader(
        subRange:    some(NodeTagRange.new(respTop + 1.u256, reqTop)),
        accKey:      accounts[nSlotLists-1].accKey,
        storageRoot: accounts[nSlotLists-1].storageRoot)
    # assigning empty slice isa ok
    dd.leftOver = dd.leftOver & accounts[nSlotLists ..< nAccounts]

  trace trSnapRecvReceived & "StorageRanges", peer, nAccounts, nSlotLists,
    nProof, nLeftOver=dd.leftOver.len, stateRoot

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
