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
  eth/[common/eth_types, p2p],
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
  #  slots*: seq[seq[SnapStorage]]
  #  proof*: SnapStorageProof

  GetStorageRanges* = object
    leftOver*: seq[SnapSlotQueueItemRef]
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

proc addLeftOver*(
    dd: var GetStorageRanges;              ## Descriptor
    accounts: seq[AccountSlotsHeader];     ## List of items to re-queue
    forceNew = false;                      ## Begin new block regardless
      ) =
  ## Helper for maintaining the `leftOver` queue
  if 0 < accounts.len:
    if accounts[0].firstSlot != Hash256() or dd.leftOver.len == 0:
      dd.leftOver.add SnapSlotQueueItemRef(q: accounts)
    else:
      dd.leftOver[^1].q = dd.leftOver[^1].q & accounts

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
    maybeIv = none(NodeTagRange)

  if nAccounts == 0:
    return err(ComEmptyAccountsArguments)
  if accounts[0].firstSlot != Hash256():
    # Set up for range
    maybeIv = some(NodeTagRange.new(
      accounts[0].firstSlot.to(NodeTag), high(NodeTag)))

  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetStorageRanges", peer,
      nAccounts, stateRoot, bytesLimit=snapRequestBytesLimit

  let snStoRanges = block:
    let rc = await buddy.getStorageRangesReq(
      stateRoot, accounts.mapIt(it.accHash), maybeIv)
    if rc.isErr:
      return err(ComNetworkProblem)
    if rc.value.isNone:
      trace trSnapRecvTimeoutWaiting & "for reply to GetStorageRanges", peer,
        nAccounts
      return err(ComResponseTimeout)
    if nAccounts < rc.value.get.slots.len:
      # Ooops, makes no sense
      return err(ComTooManyStorageSlots)
    rc.value.get

  let
    nSlots = snStoRanges.slots.len
    nProof = snStoRanges.proof.len

  if nSlots == 0:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#getstorageranges-0x02:
    #
    # Notes:
    # * Nodes must always respond to the query.
    # * If the node does not have the state for the requested state root or
    #   for any requested account hash, it must return an empty reply. It is
    #   the responsibility of the caller to query an state not older than 128
    #   blocks; and the caller is expected to only ever query existing accounts.
    trace trSnapRecvReceived & "empty StorageRanges", peer,
      nAccounts, nSlots, nProof, stateRoot, firstAccount=accounts[0].accHash
    return err(ComNoStorageForAccounts)

  # Assemble return structure for given peer response
  var dd = GetStorageRanges(data: AccountStorageRange(proof: snStoRanges.proof))

  # Filter `slots` responses:
  # * Accounts for empty ones go back to the `leftOver` list.
  for n in 0 ..< nSlots:
    # Empty data for a slot indicates missing data
    if snStoRanges.slots[n].len == 0:
      dd.addLeftOver @[accounts[n]]
    else:
      dd.data.storages.add AccountSlots(
        account: accounts[n], # known to be no fewer accounts than slots
        data: snStoRanges.slots[n])

  # Complete the part that was not answered by the peer
  if nProof == 0:
    dd.addLeftOver accounts[nSlots ..< nAccounts] # empty slice is ok
  else:
    if snStoRanges.slots[^1].len == 0:
      # `dd.data.storages.len == 0` => `snStoRanges.slots[^1].len == 0` as
      # it was confirmed that `0 < nSlots == snStoRanges.slots.len`
      return err(ComNoDataForProof)

    # If the storage data for the last account comes with a proof, then it is
    # incomplete. So record the missing part on the `dd.leftOver` list.
    let top = dd.data.storages[^1].data[^1].slotHash.to(NodeTag)

    # Contrived situation with `top==high()`: any right proof will be useless
    # so it is just ignored (i.e. `firstSlot` is zero in first slice.)
    if top < high(NodeTag):
      dd.addLeftOver @[AccountSlotsHeader(
        firstSlot:   (top + 1.u256).to(Hash256),
        accHash:     accounts[nSlots-1].accHash,
        storageRoot: accounts[nSlots-1].storageRoot)]
    dd.addLeftOver accounts[nSlots ..< nAccounts] # empty slice is ok

  let nLeftOver = dd.leftOver.foldl(a + b.q.len, 0)
  trace trSnapRecvReceived & "StorageRanges", peer,
    nAccounts, nSlots, nProof, nLeftOver, stateRoot

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
