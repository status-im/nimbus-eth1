# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  results,
  ./[config, transition]

# we are using chronicles LogLevel
# instead of our LogLevel
import types except LogLevel

when defined(chronicles_runtime_filtering):
  import chronicles

when defined(chronicles_runtime_filtering):
  proc toLogLevel(v: int): LogLevel =
    case v
    of 1: LogLevel.ERROR
    of 2: LogLevel.WARN
    of 3: LogLevel.INFO
    of 4: LogLevel.DEBUG
    of 5: LogLevel.TRACE
    else: LogLevel.NONE

  proc setVerbosity(v: int) =
    let level = v.toLogLevel
    setLogLevel(level)

proc executeTransition(conf: T8NConf): Result[void, T8NErr] =
  var ctx = TransContext()
  ? ctx.processInputs(conf)
  let res = ? ctx.transitionAction(conf)
  ? ctx.dispatchOutput(conf, res)
  ok()

proc main() {.raises: [IOError].} =
  # https://github.com/status-im/nimbus-eth1/issues/3131
  setStdIoUnbuffered()

  let conf = try:
               T8NConf.init()
             except CatchableError as exc:
               stderr.writeLine(exc.msg)
               quit(QuitFailure)
  when defined(chronicles_runtime_filtering):
    setVerbosity(conf.verbosity)
  executeTransition(conf).isOkOr:
    stderr.writeLine(error.msg)
    quit(error.code.int)

main()
