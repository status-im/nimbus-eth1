# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronicles, chronos],
  pkg/eth/[common, rlp],
  pkg/stew/[byteutils, interval_set, sorted_set],
  pkg/results,
  ../../../db/storage_types,
  ../../../common,
  ../worker_desc,
  ./headers_unproc

logScope:
  topics = "flare db"

const
  extraTraceMessages = false
    ## Enabled additional logging noise

  LhcStateKey = 1.flareStateKey

type
  SavedDbStateSpecs = tuple
    number: BlockNumber
    hash: Hash256
    parent: Hash256

# ------------------------------------------------------------------------------
# Private debugging & logging helpers
# ------------------------------------------------------------------------------

formatIt(Hash256):
  it.data.toHex

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc fetchLinkedHChainsLayout(ctx: FlareCtxRef): Opt[LinkedHChainsLayout] =
  let data = ctx.db.ctx.getKvt().get(LhcStateKey.toOpenArray).valueOr:
    return err()
  try:
    result = ok(rlp.decode(data, LinkedHChainsLayout))
  except RlpError:
    return err()


proc fetchSavedState(ctx: FlareCtxRef): Opt[SavedDbStateSpecs] =
  let db = ctx.db
  var val: SavedDbStateSpecs
  val.number = db.getSavedStateBlockNumber()

  if db.getBlockHash(val.number, val.hash):
    var header: BlockHeader
    if db.getBlockHeader(val.hash, header):
      val.parent = header.parentHash
      return ok(val)

  err()


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbStoreLinkedHChainsLayout*(ctx: FlareCtxRef): bool =
  ## Save chain layout to persistent db
  const info = "dbStoreLinkedHChainsLayout"
  if ctx.layout == ctx.lhc.lastLayout:
    when extraTraceMessages:
      trace info & ": no layout change"
    return false

  let data = rlp.encode(ctx.layout)
  ctx.db.ctx.getKvt().put(LhcStateKey.toOpenArray, data).isOkOr:
    raiseAssert info & " put() failed: " & $$error

  # While executing blocks there are frequent save cycles. Otherwise, an
  # extra save request might help to pick up an interrupted sync session.
  let txLevel = ctx.db.level()
  if txLevel == 0:
    let number = ctx.db.getSavedStateBlockNumber()
    ctx.db.persistent(number).isOkOr:
      debug info & ": failed to save persistently", error=($$error)
      return false
  else:
    when extraTraceMessages:
      trace info & ": not saved, tx pending", txLevel
    return false

  when extraTraceMessages:
    trace info & ": saved pesistently on DB"
  true


proc dbLoadLinkedHChainsLayout*(ctx: FlareCtxRef) =
  ## Restore chain layout from persistent db
  when extraTraceMessages:
    const info = "dbLoadLinkedHChainsLayout"

  let rc = ctx.fetchLinkedHChainsLayout()
  if rc.isOk:
    ctx.lhc.layout = rc.value
    let (uMin,uMax) = (rc.value.base+1, rc.value.least-1)
    if uMin <= uMax:
      # Add interval of unprocessed block range `(B,L)` from README
      ctx.headersUnprocSet(uMin, uMax)
    when extraTraceMessages:
      trace info & ": restored layout from DB"
  else:
    let val = ctx.fetchSavedState().expect "saved states"
    ctx.lhc.layout = LinkedHChainsLayout(
      base:        val.number,
      baseHash:    val.hash,
      least:       val.number,
      leastParent: val.parent,
      final:       val.number,
      finalHash:   val.hash)
    when extraTraceMessages:
      trace info & ": new layout"

  ctx.lhc.lastLayout = ctx.layout


# ------------------

proc dbStashHeaders*(
    ctx: FlareCtxRef;
    first: BlockNumber;
    revBlobs: openArray[Blob];
      ) =
  ## Temporarily store header chain to persistent db (oblivious of the chain
  ## layout.) The headers should not be stashed if they are imepreted and
  ## executed on the database, already.
  ##
  ## The `revBlobs[]` arguments are passed in reverse order so that block
  ## numbers apply as
  ## ::
  ##    #first     -- revBlobs[^1]
  ##    #(first+1) -- revBlobs[^2]
  ##    ..
  ##
  const info = "dbStashHeaders"
  let
    kvt = ctx.db.ctx.getKvt()
    last = first + revBlobs.len.uint - 1
  for n,data in revBlobs:
    let key = flareHeaderKey(last - n.uint)
    kvt.put(key.toOpenArray, data).isOkOr:
      raiseAssert info & ": put() failed: " & $$error
  when extraTraceMessages:
    trace info & ": headers stashed on DB",
      iv=BnRange.new(first, last), nHeaders=revBlobs.len

proc dbPeekHeader*(ctx: FlareCtxRef; num: BlockNumber): Opt[BlockHeader] =
  ## Retrieve some stashed header.
  let
    key = flareHeaderKey(num)
    rc = ctx.db.ctx.getKvt().get(key.toOpenArray)
  if rc.isOk:
    try:
      return ok(rlp.decode(rc.value, BlockHeader))
    except RlpError:
      discard
  err()

proc dbPeekParentHash*(ctx: FlareCtxRef; num: BlockNumber): Opt[Hash256] =
  ## Retrieve some stashed parent hash.
  ok (? ctx.dbPeekHeader num).parentHash

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
