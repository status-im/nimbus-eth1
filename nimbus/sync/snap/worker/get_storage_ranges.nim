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
  "../.."/[protocol, protocol/trace_config],
  ".."/[range_desc, worker_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

type
  GetStorageRangesError* = enum
    GsreNothingSerious
    GsreNoStorageForAccounts
    GsreTooManyStorageSlots
    GsreNetworkProblem
    GsreResponseTimeout

  # SnapStorage* = object
  #  slotHash*: Hash256
  #  slotData*: Blob
  #
  # SnapStorageRanges* = object
  #  slots*: seq[seq[SnapStorage]]
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
    iv: Option[LeafRange]
      ): Future[Result[Option[SnapStorageRanges],void]] {.async.} =
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

proc getStorageRangesImpl(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;
    accounts: seq[AccountSlotsHeader],
    iv: Option[LeafRange]
      ): Future[Result[GetStorageRanges,GetStorageRangesError]] {.async.} =
  ## Fetch data using the `snap#` protocol, returns the range covered.
  let
    peer = buddy.peer
    nAccounts = accounts.len

  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetStorageRanges", peer,
      nAccounts, stateRoot, bytesLimit=snapRequestBytesLimit

  var dd = block:
    let rc = await buddy.getStorageRangesReq(
      stateRoot, accounts.mapIt(it.accHash), iv)
    if rc.isErr:
      return err(GsreNetworkProblem)
    if rc.value.isNone:
      trace trSnapRecvTimeoutWaiting & "for reply to GetStorageRanges", peer
      return err(GsreResponseTimeout)
    let snStoRanges = rc.value.get
    if nAccounts < snStoRanges.slots.len:
      # Ooops, makes no sense
      return err(GsreTooManyStorageSlots)
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
      nAccounts, nStorages, nProof, stateRoot
    return err(GsreNoStorageForAccounts)

  # Complete response data
  for n in 0 ..< nStorages:
    dd.data.storages[n].account = accounts[n]
  dd.leftOver = accounts[nStorages ..< nAccounts]

  # Notice that `dd.leftOver.len < nAccounts` as 0 < nStorages

  trace trSnapRecvReceived & "StorageRanges", peer,
    nAccounts, nStorages, nProof, nLeftOver=dd.leftOver.len, stateRoot

  return ok(dd)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getStorageRanges*(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;
    accounts: seq[AccountSlotsHeader],
      ): Future[Result[GetStorageRanges,GetStorageRangesError]] {.async.} =
  return await buddy.getStorageRangesImpl(stateRoot, accounts, none(LeafRange))

proc getStorageRanges*(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;
    accounts: seq[AccountSlotsHeader],
    iv: LeafRange
      ): Future[Result[GetStorageRanges,GetStorageRangesError]] {.async.} =
  return await buddy.getStorageRangesImpl(stateRoot, accounts, some(iv))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
