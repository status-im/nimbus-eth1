# Fluffy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import beacon_chain/spec/presets, beacon_chain/spec/forks

func getBlockRootsIndex*(slot: Slot): uint64 =
  slot mod SLOTS_PER_HISTORICAL_ROOT

func getBlockRootsIndex*(beaconBlock: SomeForkyBeaconBlock): uint64 =
  getBlockRootsIndex(beaconBlock.slot)
