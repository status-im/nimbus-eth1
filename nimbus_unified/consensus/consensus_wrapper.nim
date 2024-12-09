# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#TODO: Clean these imports
import
  std/[os, atomics, random, terminal, times, exitprocs, sequtils],
  metrics,
  beacon_chain/[nimbus_beacon_node, nimbus_binary_common],
  beacon_chain/spec/forks,
  beacon_chain/[beacon_chain_db, trusted_node_sync],
  beacon_chain/networking/network_metadata_downloads,
  chronos,
  chronicles,
  stew/io2,
  eth/p2p/discoveryv5/[enr, random2],
  ../configs/nimbus_configs,
  beacon_chain/consensus_object_pools/vanity_logs/vanity_logs,
  beacon_chain/statusbar,
  beacon_chain/nimbus_binary_common,
  beacon_chain/spec/[forks, digest, helpers],
  beacon_chain/spec/datatypes/base,
  beacon_chain/[beacon_chain_db, trusted_node_sync, beacon_node],
  beacon_chain/spec/weak_subjectivity,
  beacon_chain/rpc/[rest_beacon_api, rest_api, state_ttl_cache],
  beacon_chain/consensus_object_pools/blob_quarantine,
  beacon_chain/networking/[topic_params, network_metadata, network_metadata_downloads],
  beacon_chain/spec/datatypes/[bellatrix],
  beacon_chain/sync/[sync_protocol],
  beacon_chain/validators/[keystore_management, beacon_validators],
  beacon_chain/consensus_object_pools/[blockchain_dag],
  beacon_chain/spec/
    [beaconstate, state_transition, state_transition_epoch, validator, ssz_codec]

export nimbus_configs

when defined(posix):
  import system/ansi_c

from beacon_chain/spec/datatypes/deneb import SignedBeaconBlock
from beacon_chain/beacon_node_light_client import
  shouldSyncOptimistically, initLightClient, updateLightClientFromDag
from libp2p/protocols/pubsub/gossipsub import TopicParams, validateParameters, init

## log
logScope:
  topics = "Consensus layer"

proc handleStartingOption(config: var BeaconNodeConf) {.raises: [CatchableError].} =
  let rng = HmacDrbgContext.new()

  # More options can be added, might be out of scope given that they exist in eth2
  case config.cmd
  of BNStartUpCmd.noCommand:
    doRunBeaconNode(config, rng)
  of BNStartUpCmd.trustedNodeSync:
    if config.blockId.isSome():
      error "--blockId option has been removed - use --state-id instead!"
      quit 1

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
