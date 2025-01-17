# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.
import
  std/atomics,
  metrics,
  chronos,
  chronicles,
  ../configs/nimbus_configs,
  #eth2
  beacon_chain/[beacon_chain_db, beacon_node, nimbus_beacon_node, nimbus_binary_common],
  beacon_chain/rpc/[rest_beacon_api, rest_api],
  beacon_chain/networking/[network_metadata, network_metadata_downloads],
  beacon_chain/validators/[keystore_management]

export nimbus_configs

## log
logScope:
  topics = "Consensus layer"

proc checkForConsensusShutdown(config: BeaconNodeConf) {.async.} =
  while isShutDownRequired.load() == false:
    await sleepAsync(cNimbusServiceTimeoutMs)

  if isShutDownRequired.load() == true:
    bnStatus = BeaconNodeStatus.Stopping

# handles option of eth2 beacon node
proc handleStartingOption(config: var BeaconNodeConf) {.raises: [CatchableError].} =
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
    isShutDownRequired.store(true)
  else:
    notice("unknown option")
    isShutDownRequired.store(true)

proc consensusWrapper*(params: ServiceParameters) {.raises: [CatchableError].} =
  doAssert params.layerConfig.kind == Consensus

  try:
    var config = params.layerConfig.consensusConfig
    discard config.checkForConsensusShutdown()
    config.handleStartingOption()
  except CatchableError as e:
    fatal "error", message = e.msg
    isShutDownRequired.store(true)

  isShutDownRequired.store(true)
  warn "\tExiting consensus layer"
