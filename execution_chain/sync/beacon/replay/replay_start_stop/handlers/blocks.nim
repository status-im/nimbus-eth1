# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Overlay handler for replay environment

{.push raises:[].}

import
  pkg/chronos,
  ../../../../wire_protocol/types,
  ../../replay_runner/runner_dispatch/dispatch_blocks,
  ../../replay_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchBodiesReplay*(
   buddy: BeaconBuddyRef;
   req: BlockBodiesRequest;
     ): Future[Result[FetchBodiesData,BeaconError]]
     {.async: (raises: []).} =
  ## Replacement for `getBlockBodies()` handler.
  await buddy.fetchBodiesHandler(req)


proc importBlockReplay*(
    ctx: BeaconCtxRef;
    maybePeer: Opt[BeaconBuddyRef];
    ethBlock: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `importBlock()` handler.
  await ctx.importBlockHandler(maybePeer, ethBlock, effPeerID)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
