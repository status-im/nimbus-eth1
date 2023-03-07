# Nimbus
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
  chronicles,
  chronos,
  eth/[common, p2p],
  ../sync_desc,
  ../misc/sync_ctrl,
  ./worker_desc,
  ./worker/com/[com_error, get_block_header]

logScope:
  topics = "snap-ctrl"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateBeaconHeaderFromFile*(
    buddy: SnapBuddyRef;             # Worker peer
      ) {.async.} =
  ## This function updates the beacon header cache by import from the file name
  ## argument `fileName`. The first line of the contents of the file looks like
  ## * `0x<hex-number>` -- hash of block header
  ## * `<decimal-number>` -- block number
  ## This function is typically used for testing and debugging.
  let
    ctx = buddy.ctx

    hashOrNum = block:
      let rc = ctx.exCtrlFile.syncCtrlHashOrBlockNumFromFile
      if rc.isErr:
        return
      rc.value

    peer = buddy.peer

  var
    rc = Result[BlockHeader,ComError].err(ComError(0))
    isHash = hashOrNum.isHash # so that the value can be logged

  # Parse value dump and fetch a header from the peer (if any)
  try:
    if isHash:
      let hash = hashOrNum.hash
      trace "External beacon info", peer, hash
      if hash != ctx.pool.beaconHeader.hash:
        rc = await buddy.getBlockHeader(hash)
    else:
      let num = hashOrNum.number
      trace "External beacon info", peer, num
      if ctx.pool.beaconHeader.blockNumber < num:
        rc = await buddy.getBlockHeader(num)
  except CatchableError as e:
    let
      name {.used.} = $e.name
      msg {.used.} = e.msg
    trace "Exception while parsing beacon info", peer, isHash, name, msg

  if rc.isOk:
    if ctx.pool.beaconHeader.blockNumber < rc.value.blockNumber:
      ctx.pool.beaconHeader = rc.value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
