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
  ../../../../wire_protocol,
  ../../replay_runner/runner_dispatch/dispatch_headers,
  ../../replay_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc beginHeadersReplay*(
    buddy: BeaconBuddyRef;
      ) {.async: (raises: []).} =
  ## ..
  await buddy.beginHeadersHandler()


proc fetchHeadersReplay*(
    buddy: BeaconBuddyRef;
    req: BlockHeadersRequest;
      ): Future[Result[FetchHeadersData,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `getBlockHeaders()` handler.
  await buddy.fetchHeadersHandler(req)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
