# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay environment.

{.push raises:[].}

import
  std/[os, streams, syncio],
  pkg/chronicles,
  ../replay_reader/[reader_init, reader_reclog],
  ../replay_desc

const
  dir = "/alien2/Ethereum.d/mainnet~diagnostics"
  name = "latest-trace.log" # & ".gz"
  file = dir / name

ReplayReaderRef.init(file.newFileStream fmRead).recLog stdout.recLogPrint()

# End
