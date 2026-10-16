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
    finHeader: Header;
    info: static[string];
      ) =
  var count = 0
  if leastBn == 1:
    # If the header chain links to Genesis, only the last finalised header
    # needs to be stored. BAL download starts not before the first finalised
    # entry.
    ctx.pool.cacheDB.putHeader(finHeader, info).isOkOr:
      return
    count.inc
  else:
    # The whole sub-chain is needed. Each header potentially refers to a
    # BAL to be fetched.
    for header in ctx.hdrCache.incrFrom():
      # Range is leastBn .. topBn
      if leastBn <= header.number:
        if finHeader.number < header.number:
          break
        ctx.pool.cacheDB.putHeader(header, info).isOkOr:
          return
        count.inc
  # Set a flag when Amsterdam was reached
  if not ctx.pool.balSupported:
    ctx.pool.cacheDB.lastHeader(info).isErrOr:
      if ctx.chain.com.isAmsterdamOrLater(value.timestamp):
        ctx.pool.balSupported = true                # so state download ok, now
  ctx.pool.lastConsNum = ctx.hdrCache.head.number
  chronicles.info info & ": Registered headers", leastBn,
    finHeader=finHeader.number, count,
    lastConsHead=ctx.pool.lastConsNum,
    consHead=ctx.hdrCache.latestConsHeadNumber, syncState=($ctx.syncState),
    onAmsterdamOrLater=ctx.pool.balSupported

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

  # Check whether the finalised hash has changed, at all. There is no point
  # fetching headers, otherwise.
  ctx.pool.cacheDB.lastBlockHash(info).isErrOr:
    if value == ctx.hdrCache.latestFinHash():
      ctx.pool.lastNoHdrsLog.logCtrl(noHeadersLogWaitInterval):
        debug info & ": Finalised CL hash has not changed, yet",
          syncState=($ctx.syncState)
      return ok()

  # Define event handler to complete beacon syncer download
  proc storeTopHeaderCB(state: BeaconNotifierState) =
    case state:
    of ok:
      let rc = ctx.hdrCache.finHeader()
      if rc.isOk and firstNum <= rc.value.number:
        ctx.storeCachedHeaders(firstNum, rc.value, info)
      else:
        trace info & ": No finalised header for now"
    of reset:
      error info & ": Header chain wrong branch => reset"
      ctx.pool.resetReq = true
    of failed:
      discard
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
  ctx.pool.lastTrggHdrsLog.logCtrl(triggeredHeadersLogWaitInterval):
    trace info & ": Triggered headers downloading", firstNum,
      syncState=($ctx.syncState), nSyncPeers=ctx.nSyncPeers(),
      nEthPeers=ctx.nEthPeers()
  ok()

proc headerDownloadCancel*(ctx: SnapCtxRef) =
  ## Terminate any ongoing download
  discard ctx.pool.beaconSync.singleReset()
  ctx.pool.headersSynced = true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
