# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Tool to download chain history data from full node and export it.

{.push raises: [].}

import
  std/os,
  confutils,
  stew/io2,
  chronicles,
  chronos,
  json_rpc/rpcclient,
  ../bridge/common/rpc_helpers,
  eth_data_exporter/[exporter_conf, cl_data_exporter, el_data_exporter]

chronicles.formatIt(IoErrorCode):
  $it

proc newRpcClient(web3Url: Web3Url): RpcClient =
  # TODO: I don't like this API. I think the creation of the RPC clients should
  # already include the URL. And then an optional connect may be necessary
  # depending on the protocol.
  let client: RpcClient =
    case web3Url.kind
    of HttpUrl:
      newRpcHttpClient()
    of WsUrl:
      newRpcWebSocketClient()

  client

proc connectRpcClient(
    client: RpcClient, web3Url: Web3Url
): Future[Result[void, string]] {.async.} =
  case web3Url.kind
  of HttpUrl:
    try:
      await RpcHttpClient(client).connect(web3Url.url)
      ok()
    except CatchableError as e:
      return err(e.msg)
  of WsUrl:
    try:
      await RpcWebSocketClient(client).connect(web3Url.url)
      ok()
    except CatchableError as e:
      return err(e.msg)

when isMainModule:
  {.pop.}
  let config = ExporterConf.load()
  {.push raises: [].}

  setLogLevel(config.logLevel)

  let dataDir = config.dataDir.string
  if not isDir(dataDir):
    let res = createPath(dataDir)
    if res.isErr():
      fatal "Error occurred while creating data directory",
        dir = dataDir, error = ioErrorMsg(res.error)
      quit QuitFailure

  case config.cmd
  of ExporterCmd.history:
    case config.historyCmd
    of HistoryCmd.exportBlockData:
      let client = newRpcClient(config.web3Url)
      let connectRes = waitFor client.connectRpcClient(config.web3Url)
      if connectRes.isErr():
        fatal "Failed connecting to JSON-RPC client", error = connectRes.error
        quit QuitFailure

      defer:
        waitFor client.close()

      let fileName = dataDir / "block-data-" & $config.blockNumber & ".yaml"
      (waitFor client.exportBlock(config.blockNumber, fileName)).isOkOr:
        fatal "Failed exporting block data",
          blockNumber = config.blockNumber, error = error
        quit QuitFailure

      info "Block data exported successfully", fileName = fileName
  of ExporterCmd.beacon:
    let (cfg, forkDigests, _) = getBeaconData(config.network)

    case config.beaconCmd
    of BeaconCmd.exportLCBootstrap:
      waitFor exportLCBootstrapUpdate(
        config.restUrl, string config.dataDir, config.trustedBlockRoot, cfg, forkDigests
      )
    of BeaconCmd.exportLCUpdates:
      waitFor exportLCUpdates(
        config.restUrl,
        string config.dataDir,
        config.startPeriod,
        config.count,
        cfg,
        forkDigests,
      )
    of BeaconCmd.exportLCFinalityUpdate:
      waitFor exportLCFinalityUpdate(
        config.restUrl, string config.dataDir, cfg, forkDigests
      )
    of BeaconCmd.exportLCOptimisticUpdate:
      waitFor exportLCOptimisticUpdate(
        config.restUrl, string config.dataDir, cfg, forkDigests
      )
    of BeaconCmd.exportHistoricalRoots:
      waitFor exportHistoricalRoots(
        config.restUrl, string config.dataDir, cfg, forkDigests
      )
    of BeaconCmd.exportBlockProof:
      exportBlockProof(
        string config.dataDir, string config.eraDir, config.slotNumber, config.network
      )
