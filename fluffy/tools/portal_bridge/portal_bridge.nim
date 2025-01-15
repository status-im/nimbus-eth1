# Fluffy
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#
# The Portal bridge;s task is to inject content into the different Portal networks.
# The bridge acts as a middle man between a content provider (i.e. full node)
# through its exposed API (REST, JSON-RCP, ...), and a Portal node, through the
# Portal JSON-RPC API.
#
# Beacon Network:
#
# For the beacon network a consensus full node is required on one side,
# making use of the Beacon Node REST-API, and a Portal node on the other side,
# making use of the Portal JSON-RPC API.
#
# Portal Network <-> Portal Client (e.g. fluffy) <--JSON-RPC--> bridge <--REST--> consensus client (e.g. Nimbus-eth2)
#
# The Consensus client must support serving the Beacon LC data.
#
# Bootstraps and updates can be backfilled, however how to do this for multiple
# bootstraps is still unsolved.
#
# Updates, optimistic updates and finality updates are injected as they become
# available.
# Updating these as better updates come available is not yet implemented.
#
# History network:
#
# For the history network a execution client is required on one side, making use
# of the EL JSON-RPC API, and a Portal node on the other side, making use of the
# Portal JSON-RPC API.
#
# Portal Network <-> Portal Client (e.g. fluffy) <--Portal JSON-RPC--> bridge <--EL JSON-RPC--> execution client / web3 provider
#
# Backfilling is not yet implemented. Backfilling will make use of Era1 files.
#
# State network:
#
# To be implemented
#

{.push raises: [].}

import
  chronos,
  chronicles,
  confutils,
  confutils/std/net,
  ../../logging,
  ./[
    portal_bridge_conf, portal_bridge_beacon, portal_bridge_history, portal_bridge_state
  ]

type PortalBridgeStatus = enum
  Running
  Stopping

template pollWhileRunning(status: PortalBridgeStatus) =
  while status == PortalBridgeStatus.Running:
    try:
      poll()
    except CatchableError as e:
      warn "Exception in poll()", exc = e.name, err = e.msg

when isMainModule:
  {.pop.}
  let config = PortalBridgeConf.load()
  {.push raises: [].}

  setupLogging(config.logLevel, config.logStdout, none(OutFile))

  var bridgeStatus = PortalBridgeStatus.Running

  # Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except Exception as e:
        raiseAssert e.msg # shouldn't happen

    notice "Shutting down after having received SIGINT"
    bridgeStatus = PortalBridgeStatus.Stopping

  try:
    setControlCHook(controlCHandler)
  except Exception as e: # TODO Exception
    warn "Cannot set ctrl-c handler", msg = e.msg

  case config.cmd
  of PortalBridgeCmd.beacon:
    runBeacon(config)

    pollWhileRunning(bridgeStatus)
    # TODO: Implement stop/cleanup for beacon bridge
  of PortalBridgeCmd.history:
    runHistory(config)

    pollWhileRunning(bridgeStatus)
    # TODO: Implement stop/cleanup for history bridge
  of PortalBridgeCmd.state:
    let bridge = waitFor runState(config)

    pollWhileRunning(bridgeStatus)
    waitFor bridge.stop()
