# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronicles, chronos],
  ../../../beacon,
  ../[mpt, worker_desc]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc storeCachedHeaders(
    ctx: SnapCtxRef;
    leastBn: BlockNumber;
    info: static[string];
      ) =
  var count = 0
  for header in ctx.hdrCache.incrFrom():
    if leastBn <= header.number:
      ctx.pool.mptAsm.putHeader(header).isOkOr:
        chronicles.error info & ": Unable to register cached headers",
          blockNumber=header.number, `error`=error
        return
      count.inc
  trace info & ": Registered headers", count

proc minStateNum(
    ctx: SnapCtxRef;
    info: static[string];
      ): BlockNumber =
  let haveData = ctx.pool.mptAsm.hasStateData().valueOr:
    chronicles.error info & ": Failed to check exisitence of state data",
      `error`=error
    return BlockNumber(0)
  if haveData:
    result = BlockNumber high(uint64)
    for w in ctx.pool.mptAsm.walkStateData():
      if w.error.len == 0 and w.number < result:
        result = w.number
  # BlockNumber(0)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headerDownloadTrigger*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Result[void,TriggerRunError] =
  ## Tell beacon syncer to download headers and collect the result
  ## afterwards.
  let
    bcSync = ctx.pool.beaconSync
    header = ctx.pool.mptAsm.lastHeader().valueOr: ctx.chain.com.genesisHeader()
    leastBn = if 0 < header.number: header.number+1 # discard smaller ones
              else: ctx.minStateNum(info)           # ..

  proc storeTopHeaderCB(ok: bool) =
    if ok:
      ctx.storeCachedHeaders(leastBn, info)
    bcSync.singleReset().isOkOr:
      chronicles.error info & ": Unable to reset header download",
        `error`=error
    ctx.pool.headersSynced = true

  bcSync.singleRun(header, storeTopHeaderCB).isOkOr:
    if ctx.nEthPeers() == 0:
      chronicles.info info & ": Waiting for eth/xx peers",
        syncState=($ctx.syncState), nSyncPeers=ctx.nSyncPeers()
    elif ctx.hdrCache.latestConsHeadNumber() == 0:
      chronicles.info info & ": Waiting for CL to send updates",
        syncState=($ctx.syncState), nSyncPeers=ctx.nSyncPeers()
    elif ctx.pool.headersSynced:                    # otherwise ongoing download
      chronicles.error info & ": Unable to trigger ref headers download",
        syncState=($ctx.syncState), nSyncPeers=ctx.nSyncPeers(), `error`=error
    return err(error)

  ctx.pool.headersSynced = false                    # reset download flag
  trace info & ": Triggered headers downloading", `from`=leastBn
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
