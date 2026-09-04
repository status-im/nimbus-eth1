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
{.push raises: [].}

import
  std/os,
  unittest2,
  results,
  ../../tools/evmstate/[evmstate, config]

proc runTest(filePath: string): Result[seq[StateResult], string] =
  let conf = StateConf(
    disableOutput: true,
    postState    : true,
    dumpEnabled  : true,
    enableError  : false,
    sanitizeEnv  : true,
  )

  evmstate.prepareAndRun(filePath, conf, seq[StateResult])

proc processFile*(filePath: string, statelessEnabled = false, parallelEnabled = false, skipFiles: seq[string] = @[]) =
  let
    fileName = filePath.splitPath().tail

  if fileName in skipFiles:
    test filePath:
      skip()
    return

  let list = runTest(filePath)
  if list.isErr:
    debugEcho list.error
    check list.isOk
    return

  for x in list.value:
    let z = x
    test z.name & " from " & filePath:
      check z.pass == true
      check z.error.len == 0

when isMainModule:
  evmstate.evmStateMain()
