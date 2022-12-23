# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  beacon_chain/beacon_clock,
  beacon_chain/nimbus_binary_common,
  beacon_chain/conf

type
  NetworkInitData* = object
    clock*: BeaconClock
    metaData*: Eth2NetworkMetadata
    forks*: ForkDigests
    genesis_validators_root*: Eth2Digest

proc loadNetworkData*(networkName: string): NetworkInitData {.raises: [CatchableError, Defect].}=
  let
    metadata =
      try:
        loadEth2Network(some("mainnet"))
      except CatchableError as exc:
        raiseAssert(exc.msg)

    genesisState =
      try:
        template genesisData(): auto = metadata.genesisData
        newClone(readSszForkedHashedBeaconState(
          metadata.cfg, genesisData.toOpenArrayByte(genesisData.low, genesisData.high)))
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    beaconClock = BeaconClock.init(getStateField(genesisState[], genesis_time))

    genesis_validators_root =
      getStateField(genesisState[], genesis_validators_root)

    forks = newClone ForkDigests.init(metadata.cfg, genesis_validators_root)

  return NetworkInitData(
    clock: beaconClock,
    metaData: metaData,
    forks: forks[],
    genesis_validators_root: genesis_validators_root
  )
