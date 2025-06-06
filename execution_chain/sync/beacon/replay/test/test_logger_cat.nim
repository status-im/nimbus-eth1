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
##
## This file provides a `main()` program that reads from `stdin` and
## prints to `stdout`.

{.push raises:[].}

import
  std/[streams, syncio],
  pkg/chronicles,
  ../replay_reader/[reader_init, reader_reclog],
  ../replay_desc

ReplayReaderRef.init(newFileStream stdin).recLog stdout.recLogPrint()

# End
