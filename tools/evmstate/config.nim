# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, options],
  confutils, confutils/defs

export
  confutils, defs

type
  StateConf* = object of RootObj
    dumpEnabled* {.
      desc: "dumps the state after the run"
      defaultValue: false
      name: "dump" }: bool

    jsonEnabled* {.
      desc: "output trace logs in machine readable format (json)"
      defaultValue: false
      name: "json" }: bool

    debugEnabled* {.
      desc: "output full trace logs"
      defaultValue: false
      name: "debug" }: bool

    disableMemory* {.
      desc: "disable memory output"
      defaultValue: true
      name: "nomemory" }: bool

    disableStack* {.
      desc: "disable stack output"
      defaultValue: false
      name: "nostack" }: bool

    disableStorage* {.
      desc: "disable storage output"
      defaultValue: true
      name: "nostorage" }: bool

    disableReturnData* {.
      desc: "enable return data output"
      defaultValue: true
      name: "noreturndata" }: bool

    fork* {.
      desc: "choose which fork to be tested"
      defaultValue: ""
      name: "fork" }: string

    index* {.
      desc: "if index is unset, all subtest in the fork will be tested"
      defaultValue: none(int)
      name: "index" }: Option[int]

    pretty* {.
      desc: "pretty print the trace result"
      defaultValue: false
      name: "pretty" }: bool

    verbosity* {.
      desc: "sets the verbosity level"
      longDesc:
        "0 = silent, 1 = error, 2 = warn, 3 = info, 4 = debug, 5 = detail"
      defaultValue: 0
      name: "verbosity" }: int

    inputFile* {.
      desc: "json file contains state test data"
      argument }: string

const
  Copyright = "Copyright (c) 2022-" &
    CompileDate.split('-')[0] &
    " Status Research & Development GmbH"
  Version   = "Nimbus-evmstate 0.1.2"

proc init*(_: type StateConf, cmdLine = commandLineParams()): StateConf =
  {.push warning[ProveInit]: off.}
  result = StateConf.load(
    cmdLine,
    version = Version,
    copyrightBanner = Version & "\n" & Copyright
  )
  {.pop.}
