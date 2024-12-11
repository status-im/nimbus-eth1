# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#TODO: Clean these imports
import
  std/atomics,
  metrics,
  chronos,
  chronicles,
  ../configs/nimbus_configs,
  beacon_chain/[beacon_chain_db, beacon_node, nimbus_beacon_node, nimbus_binary_common],
  beacon_chain/rpc/[rest_beacon_api, rest_api],
  beacon_chain/networking/[network_metadata, network_metadata_downloads],
  beacon_chain/validators/[keystore_management]

export nimbus_configs

## log
logScope:
  topics = "Consensus layer"

# handles option of eth2 beacon node
proc handleStartingOption*(config: var BeaconNodeConf) {.raises: [CatchableError].} =
  let rng = HmacDrbgContext.new()

  # More options can be added, might be out of scope given that they exist in eth2
  case config.cmd
  of BNStartUpCmd.noCommand:
    doRunBeaconNode(config, rng)
  of BNStartUpCmd.trustedNodeSync:
    if config.blockId.isSome():
      raise newException(
        ValueError, "--blockId option has been removed - use --state-id instead!"
      )

    let
      metadata = loadEth2Network(config)
      db = BeaconChainDB.new(config.databaseDir, metadata.cfg, inMemory = false)
      genesisState = waitFor fetchGenesisState(metadata)
    waitFor db.doRunTrustedNodeSync(
      metadata, config.databaseDir, config.eraDir, config.trustedNodeUrl,
      config.stateId, config.lcTrustedBlockRoot, config.backfillBlocks, config.reindex,
      config.downloadDepositSnapshot, genesisState,
    )
    db.close()
  else:
    notice("unknonw option")
    isShutDownRequired.store(true)

proc consensusWrapper*(parameters: TaskParameters) {.raises: [CatchableError].} =
  var config = parameters.beaconNodeConfigs

  try:
    handleStartingOption(config)
  except CatchableError as e:
    fatal "error", message = e.msg
    isShutDownRequired.store(true)

  isShutDownRequired.store(true)
  warn "\tExiting consensus wrapper"
