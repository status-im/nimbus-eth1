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
  ../../../../beacon,
  ../../[cache_db, worker_desc]

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
      ctx.pool.cacheDB.putHeader(header, info).isOkOr:
        return
      count.inc
  trace info & ": Registered headers",
    count, head=ctx.hdrCache.head.number, syncState=($ctx.syncState)

proc stateNum(ctx: SnapCtxRef): BlockNumber =
  # Get block number from saved state (if any)
  let maybe = ctx.pool.cacheDB.getAccMissingIntv().valueOr:
    return BlockNumber(0)
  if maybe.isSome():
    return maybe.unsafeGet.number
  # BlockNumber(0)

proc getLastHeaderOrGenesis(ctx: SnapCtxRef): Header =
  ## Ignore errors
  var hdr = ctx.pool.cacheDB.lastHeader().valueOr:
    return ctx.chain.com.genesisHeader()
  if hdr.isNone():
    return ctx.chain.com.genesisHeader()
  hdr.unsafeGet

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
    firstNum = ctx.stateNum() + 1                   # discard smaller ones

  # Check whether there is an ongoing header download, already.
  if ctx.beaconState in
       {BeaconState.headers, BeaconState.headersFinish, BeaconState.linger}:
    # Note: The `linger` state is active when waiting for the
    #       `storeTopHeaderCB()` event handler (see below) to
    #       clean up.
    return ok()                                     # nothing to do

  # Ignoring a beacon header fetch cycle unless there are enough headers
  # available to fetch.
  let consHeadNum = ctx.hdrCache.latestConsHeadNumber()
  if consHeadNum < firstNum + nConsHeadCachedDeltaMax - 1 and
     not ctx.pool.beaconTarget:                     # maybe manual target set?
    let now = Moment.now()
    if ctx.pool.lastNoHdrsLog + noHeadersLogWaitInterval < now:
      ctx.pool.lastNoHdrsLog = now
      trace info & ": Not enough headers to download yet", firstNum,
        consHeadNum, syncState=($ctx.syncState)
    return ok()

  # Define event handler to complete beacon syncer download
  proc storeTopHeaderCB(ok: bool) =
    if ok:
      ctx.storeCachedHeaders(firstNum, info)
    bcSync.singleReset().isOkOr:
      error info & ": Unable to reset header download", `error`=error
    ctx.pool.headersSynced = true                   # mark header update done
    ctx.pool.beaconTarget = false                   # exhausted now (if any)

  # Trigger beacon syncer
  let header = ctx.getLastHeaderOrGenesis()
  bcSync.singleRun(header, storeTopHeaderCB).isOkOr:
    if ctx.nEthPeers() == 0:
      chronicles.info info & ": Waiting for eth/xx peers",
        syncState=($ctx.syncState), nSyncPeers=ctx.nSyncPeers()
    elif ctx.hdrCache.latestConsHeadNumber() == 0:
      if not ctx.pool.beaconTarget:
        chronicles.info info & ": Waiting for CL to send updates",
          syncState=($ctx.syncState), nSyncPeers=ctx.nSyncPeers(),
          nEthPeers=ctx.nEthPeers()
    elif ctx.pool.headersSynced:                    # otherwise ongoing download
      chronicles.error info & ": Unable to trigger ref headers download",
        syncState=($ctx.syncState), nSyncPeers=ctx.nSyncPeers(),
        nEthPeers=ctx.nEthPeers(), `error`=error
    return err(error)

  ctx.pool.headersSynced = false                    # mark ongoing header update
  trace info & ": Triggered headers downloading", firstNum,
    syncState=($ctx.syncState), nSyncPeers=ctx.nSyncPeers(),
    nEthPeers=ctx.nEthPeers()
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
