# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# To make the isMainModule functionality work
{.define: unittest2DisableParamFiltering.}

import
  std/os,
  unittest2,
  ../../tools/evmstate/[evmstate, config]

proc runTest(filePath: string): bool =
  let conf = StateConf(
    disableOutput: true,
    postState    : true,
    dumpEnabled  : true,
  )

  evmstate.prepareAndRun(filePath, conf)

proc processFile*(filePath: string, statelessEnabled = false, parallelEnabled = false, skipFiles: seq[string] = @[]) =
  let
    fileName = filePath.splitPath().tail

  test filePath:
    if fileName in skipFiles:
      skip()
    else:
      let testResult = runTest(filePath)
      check testResult == true

when isMainModule:
  evmstate.evmStateMain()
