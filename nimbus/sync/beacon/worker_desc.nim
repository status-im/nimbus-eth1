# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  eth/p2p,
  chronos,
  ../sync_desc

type
  BeaconBuddyData* = object
    ## Local descriptor data extension

  BeaconCtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext       ## Random generator, pre-initialised
    id*: int

  BeaconBuddyRef* = BuddyRef[BeaconCtxData,BeaconBuddyData]
    ## Extended worker peer descriptor

  BeaconCtxRef* = CtxRef[BeaconCtxData]
    ## Extended global descriptor

# End
