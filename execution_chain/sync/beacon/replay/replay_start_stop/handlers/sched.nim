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
  ../../replay_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc schedDaemonMuted*(
    ctx: BeaconCtxRef;
      ): Future[Duration]
      {.async: (raises: []).} =
  ## Replacement for `schedDaemon()` handler.
  return replayWaitMuted

proc schedStartMuted*(buddy: BeaconBuddyRef): bool =
  ## Similar to `schedDaemonMuted()`
  false

proc schedStopMuted*(buddy: BeaconBuddyRef) =
  ## Similar to `schedDaemonMuted()`
  discard

proc schedPoolMuted*(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  ## Similar to `schedDaemonMuted()`
  true

proc schedPeerMuted*(
    buddy: BeaconBuddyRef;
      ):Future[Duration]
      {.async: (raises: []).} =
  ## Similar to `schedDaemonMuted()`
  return replayWaitMuted

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
