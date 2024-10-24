# fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/forks,
  beacon_chain/beacon_clock,
  beacon_chain/conf

type NetworkInitData* = object
  clock*: BeaconClock
  metadata*: Eth2NetworkMetadata
  forks*: ForkDigests
  genesis_validators_root*: Eth2Digest

proc loadNetworkData*(networkName: string): NetworkInitData =
  let
    metadata = loadEth2Network(some("mainnet"))
    genesisState =
      try:
        template genesisData(): auto =
          metadata.genesis.bakedBytes

        newClone(
          readSszForkedHashedBeaconState(
            metadata.cfg, genesisData.toOpenArray(genesisData.low, genesisData.high)
          )
        )
      except SerializationError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    genesisTime = getStateField(genesisState[], genesis_time)
    beaconClock = BeaconClock.init(genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure

    genesis_validators_root = getStateField(genesisState[], genesis_validators_root)

    forks = newClone ForkDigests.init(metadata.cfg, genesis_validators_root)

  return NetworkInitData(
    clock: beaconClock,
    metadata: metadata,
    forks: forks[],
    genesis_validators_root: genesis_validators_root,
  )
