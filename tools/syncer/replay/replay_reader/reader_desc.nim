# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  std/streams,
  pkg/[results, zlib]

type
  ReplayRecLogPrintFn* = proc(s: seq[string]) {.gcsafe, raises: [].}
    ## Print output (e.g. used in `lineLog()`) for logger

  ReplayReadLineFn* =
      proc(rp: ReplayReaderRef): Opt[string] {.gcsafe, raises: [].}
        ## Reader filter, e.g. for zipped data

  ReplayAtEndFn* =
      proc(rp: ReplayReaderRef): bool {.gcsafe, raises: [].}
        ## Indicated end of stream

  ReplayReaderRef* = ref object
    ## Reader descriptor
    inStream*: Stream                        ## Dump file for ethxx data packets
    gzFilter*: GUnzipRef                     ## Apply GUnzip filter to stream
    readLine*: ReplayReadLineFn              ## Reader function
    atEnd*: ReplayAtEndFn                    ## EOF indicator

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
