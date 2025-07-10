# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay runner

{.push raises:[].}

import
  pkg/chronos,
  ./replay_runner/runner_dispatch,
  ./[replay_desc, replay_reader]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runDispatcher*(
    runner: ReplayRunnerRef;
    reader: ReplayReaderRef;
    stopIf: ReplayStopRunnnerFn;
      ) {.async: (raises: []).} =
  for w in reader.records():
    # Can continue?
    if stopIf():
      break

    # Dispatch next instruction record
    await runner.dispatch(w)

    # Wait for optional task switch
    try: await sleepAsync replayWaitForCompletion
    except CancelledError: break

  # Finish
  await runner.dispatchEnd()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
