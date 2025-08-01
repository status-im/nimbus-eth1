# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay environment

{.push raises:[].}

import
  ./replay/replay_reader/reader_init,
  ./replay/[replay_desc, replay_reader]

export
  ReplayReaderRef,
  captureLog,
  init

# End
