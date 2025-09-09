# Nimbus
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
# Portal Network <-> Portal Client (e.g. nimbus_portal_client) <--JSON-RPC--> bridge <--REST--> consensus client (e.g. Nimbus-eth2)
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
# Portal Network <-> Portal Client (e.g. nimbus_portal_client) <--Portal JSON-RPC--> bridge <--EL JSON-RPC--> execution client / web3 provider
#
# Backfilling is not yet implemented. Backfilling will make use of Era1 files.
#

{.push raises: [].}

import
  chronos,
  chronicles,
  confutils,
  confutils/std/net,
  ../logging,
  ./beacon/portal_beacon_bridge,
  ./history/portal_history_bridge,
  ./nimbus_portal_bridge_conf,
  beacon_chain/process_state

template pollWhileRunning() =
  while not ProcessState.stopIt(notice("Shutting down", reason = it)):
    poll()

when isMainModule:
  ProcessState.setupStopHandlers()

  let config = PortalBridgeConf.load()

  setupLogging(config.logLevel, config.logStdout, none(OutFile))

  case config.cmd
  of PortalBridgeCmd.beacon:
    runBeacon(config)

    pollWhileRunning()
    # TODO: Implement stop/cleanup for beacon bridge
  of PortalBridgeCmd.history:
    runHistory(config)

    pollWhileRunning()
    # TODO: Implement stop/cleanup for history bridge
