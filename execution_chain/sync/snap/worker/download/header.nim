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
    storeAll: bool;
    info: static[string];
      ) =
  let adb = ctx.pool.mptAsm
  if storeAll:
    # Store the whole chain
    var count = 0
    for header in ctx.hdrCache.incrFrom():
      adb.putHeader(header).isOkOr:
        chronicles.error info & ": Unable to register cached headers",
          `error`=error
        return
      count.inc
      ctx.pool.topBlockNumber = header.number
    trace info & ": Registered top headers", count
  else:
    # Store only top header
    let header = ctx.hdrCache.head()
    adb.putHeader(header).isOkOr:
      chronicles.error info & ": Unable to register cached top header",
        `error`=error
      return
    ctx.pool.topBlockNumber = header.number
    trace info & ": Registered top header"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headerDownloadTrigger*(
    ctx: SnapCtxRef;
    topOnly: bool;
    info: static[string];
      ): Result[void,TriggerRunError] =
  ## Tell beacon syncer to download headers and collect the result
  ## afterwards.
  let
    bc = ctx.pool.beaconSync
    rc = ctx.pool.mptAsm.lastHeader()
    hdr = if rc.isOk: rc.value else: ctx.chain.com.genesisHeader()

    # Never store all from genesis onwards to FCU header
    storeAll = not (rc.isErr or topOnly)

  proc storeTopHeaderCB(ok: bool) =
    if ok:
      ctx.storeCachedHeaders(storeAll, info)
    bc.singleReset().isOkOr:
      chronicles.error info & ": Unable to reset header download",
        `error`=error

  bc.singleRun(hdr, storeTopHeaderCB).isOkOr:
    if ctx.nEthPeers() == 0:
      chronicles.info info & ": Waiting for eth/xx peers"
    elif ctx.pool.topBlockNumber != 0:              # otherwise ongoing download
      chronicles.error info & ": Unable to trigger ref headers download",
        `error`=error
    return err(error)

  ctx.pool.topBlockNumber = BlockNumber(0)          # set ongoing download flag
  trace info & ": Triggered headers downloading", `from`=hdr.number
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
