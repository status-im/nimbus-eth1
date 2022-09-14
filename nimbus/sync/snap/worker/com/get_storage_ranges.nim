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
  ./get_error

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
    leftOver*: SnapSlotQueueItemRef
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
    iv: Option[LeafRange]
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
    maybeIv = none(LeafRange)

  if nAccounts == 0:
    return err(ComEmptyAccountsArguments)
  if accounts[0].firstSlot != Hash256.default:
    # Set up for range
    maybeIv = some(LeafRange.new(
      accounts[0].firstSlot.to(NodeTag), high(NodeTag)))

  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetStorageRanges", peer,
      nAccounts, stateRoot, bytesLimit=snapRequestBytesLimit

  var dd = block:
    let rc = await buddy.getStorageRangesReq(
      stateRoot, accounts.mapIt(it.accHash), maybeIv)
    if rc.isErr:
      return err(ComNetworkProblem)
    if rc.value.isNone:
      trace trSnapRecvTimeoutWaiting & "for reply to GetStorageRanges", peer,
        nAccounts
      return err(ComResponseTimeout)
    let snStoRanges = rc.value.get
    if nAccounts < snStoRanges.slots.len:
      # Ooops, makes no sense
      return err(ComTooManyStorageSlots)
    GetStorageRanges(
      data: AccountStorageRange(
        proof:    snStoRanges.proof,
        storages: snStoRanges.slots.mapIt(
          AccountSlots(
            data: it))))
  let
    nStorages = dd.data.storages.len
    nProof = dd.data.proof.len

  if nStorages == 0:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#getstorageranges-0x02:
    #
    # Notes:
    # * Nodes must always respond to the query.
    # * If the node does not have the state for the requested state root or
    #   for any requested account hash, it must return an empty reply. It is
    #   the responsibility of the caller to query an state not older than 128
    #   blocks; and the caller is expected to only ever query existing accounts.
    trace trSnapRecvReceived & "empty StorageRanges", peer,
      nAccounts, nStorages, nProof, stateRoot, firstAccount=accounts[0].accHash
    return err(ComNoStorageForAccounts)

  # Complete response data
  for n in 0 ..< nStorages:
    dd.data.storages[n].account = accounts[n]

  # Calculate what was not fetched
  if nProof == 0:
    dd.leftOver = SnapSlotQueueItemRef(q: accounts[nStorages ..< nAccounts])
  else:
    # If the storage data for the last account comes with a proof, then it is
    # incomplete. So record the missing part on the `dd.leftOver` list.
    let top = dd.data.storages[^1].data[^1].slotHash.to(NodeTag)
    if top < high(NodeTag):
      dd.leftOver = SnapSlotQueueItemRef(q: accounts[nStorages-1 ..< nAccounts])
      dd.leftOver.q[0].firstSlot = (top + 1.u256).to(Hash256)
    else:
      # Contrived situation: the proof would be useless
      dd.leftOver = SnapSlotQueueItemRef(q: accounts[nStorages ..< nAccounts])

  # Notice that `dd.leftOver.len < nAccounts` as 0 < nStorages

  trace trSnapRecvReceived & "StorageRanges", peer,
    nAccounts, nStorages, nProof, nLeftOver=dd.leftOver.q.len, stateRoot

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
