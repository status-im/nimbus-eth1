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
  ../../../../db/storage_types,
  ../../worker_desc

logScope:
  topics = "flare db"

# ------------------------------------------------------------------------------
# Private debugging & logging helpers
# ------------------------------------------------------------------------------

formatIt(Hash256):
  it.data.toHex

# ------------------------------------------------------------------------------
# Public debugging functions
# ------------------------------------------------------------------------------

proc dbVerifyStashedHeaders*(
    ctx: FlareCtxRef;
    info: static[string];
      ): Future[bool] {.async.} =
  ## For debugging. Verify integrity of stashed headers on the database.

  # Last executed block on database
  let
    db = ctx.db
    kvt = ctx.db.ctx.getKvt()
    elNum = db.getSavedStateBlockNumber()
    lyLeast = ctx.layout.least
    lyFinal = ctx.layout.final
    lyFinalHash = ctx.layout.finalHash

  if lyLeast == 0:
    return true

  if lyLeast <= elNum and 0 < elNum:
    debug info & ": base header B unsynced", elNum=elNum.bnStr, B=lyLeast.bnStr
    return false

  let iv = BnRange.new(lyLeast,lyFinal)
  trace info & ": verifying stashed headers", iv, len=(lyFinal-lyLeast+1)

  var lastHash = ctx.layout.leastParent
  for num in lyLeast .. lyFinal:
    let data = kvt.get(flareHeaderKey(num).toOpenArray).valueOr:
      debug info & ": unstashed header", num=num.bnStr
      return false

    var header: BlockHeader
    try: header = rlp.decode(data, BlockHeader)
    except RlpError:
      debug info & ": cannot decode rlp header", num=num.bnStr
      return false

    if header.number != num:
      debug info & ": wrongly addressed header",
        num=header.number.bnStr, expected=num.bnStr
      return false

    if header.parentHash != lastHash:
      debug info & ": hash mismatch", lastNum=(num-1).bnStr, lastHash,
        parentHash=header.parentHash
      return false

    lastHash = data.keccakHash

    # Allow thread change
    if (num mod 100_000) == 98_765:
      # trace info & ": thread change offer", num=num.bnStr
      await sleepAsync asyncThreadSwitchTimeSlot

  if lyFinalHash != lastHash:
    debug info & ": base header B hash mismatch", num=lyFinal.bnStr,
      hash=lyFinalHash, expected=lastHash
    return false

  trace info & ": done verifying", iv, len=(lyFinal-lyLeast+1)
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
