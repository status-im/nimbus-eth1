# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[options, os, strutils],
  confutils, stint,
  ./types

export
  options, stint

func combineForks(): string =
  for x in low(TestFork)..high(TestFork):
    result.add "- " & $x & "\n"

const
  availableForks = combineForks()

type
  HexOrInt* = distinct uint64

  T8NConf* = object of RootObj
    traceEnabled* {.
      desc: "Enable and set where to put full EVM trace logs"
      longDesc:
        "`stdout` - into the stdout output\n" &
        "`stderr` - into the stderr output\n" &
        "<file>   - into the file <file>-<txIndex>.jsonl\n" &
        "none     - output.basedir/trace-<txIndex>-<txhash>.jsonl\n"
      defaultValue: none(string)
      defaultValueDesc: "disabled"
      name: "trace" }: Option[string]

    traceMemory* {.
      desc: "Enable full memory dump in traces"
      defaultValue: false
      name: "trace.memory" }: bool

    traceNostack* {.
      desc: "Disable stack output in traces"
      defaultValue: false
      name: "trace.nostack" }: bool

    traceReturnData* {.
      desc: "Enable return data output in traces"
      defaultValue: false
      name: "trace.returndata" }: bool

    outputBaseDir* {.
      desc: "Specifies where output files are placed. Will be created if it does not exist"
      defaultValue: ""
      name: "output.basedir" }: string

    outputBody* {.
      desc: "If set, the RLP of the transactions (block body) will be written to this file"
      defaultValue: ""
      name: "output.body" }: string

    outputAlloc* {.
      desc: "Determines where to put the `alloc` of the post-state."
      longDesc:
        "`stdout` - into the stdout output\n" &
        "`stderr` - into the stderr output\n" &
        "<file>   - into the file <file>\n"
      defaultValue: "alloc.json"
      name: "output.alloc" }: string

    outputResult* {.
      desc: "Determines where to put the `result` (stateroot, txroot etc) of the post-state."
      longDesc:
        "`stdout` - into the stdout output\n" &
        "`stderr` - into the stderr output\n" &
        "<file>   - into the file <file>\n"
      defaultValue: "result.json"
      name: "output.result" }: string

    inputAlloc* {.
      desc: "`stdin` or file name of where to find the prestate alloc to use."
      defaultValue: "alloc.json"
      name: "input.alloc" }: string

    inputEnv* {.
      desc: "`stdin` or file name of where to find the prestate env to use."
      defaultValue: "env.json"
      name: "input.env" }: string

    inputTxs* {.
      desc: "`stdin` or file name of where to find the transactions to apply. " &
        "If the file extension is '.rlp', then the data is interpreted as an RLP list of signed transactions. " &
        "The '.rlp' format is identical to the output.body format."
      defaultValue: "txs.json"
      name: "input.txs" }: string

    stateReward* {.
      desc: "Mining reward. Set to -1 to disable"
      defaultValue: some(0.u256)
      defaultValueDesc: "-1"
      name: "state.reward" }: Option[UInt256]

    stateChainId* {.
      desc: "ChainID to use"
      defaultValue: 1
      name: "state.chainid" }: HexOrInt

    stateFork* {.
      desc: "Name of ruleset to use."
      longDesc: $availableForks
      defaultValue: "GrayGlacier"
      name: "state.fork" }: string

    verbosity* {.
      desc: "sets the verbosity level"
      longDesc:
        "0 = silent, 1 = error, 2 = warn, 3 = info, 4 = debug, 5 = detail"
      defaultValue: 3
      name: "verbosity" }: int

proc parseCmdArg(T: type Option[UInt256], p: string): T =
  if p == "-1":
    none(UInt256)
  elif startsWith(p, "0x"):
    some(parse(p, UInt256, 16))
  else:
    some(parse(p, UInt256, 10))

proc completeCmdArg(T: type Option[UInt256], val: string): seq[string] =
  return @[]

proc parseCmdArg(T: type HexOrInt, p: string): T =
  if startsWith(p, "0x"):
    parseHexInt(p).T
  else:
    parseInt(p).T

proc completeCmdArg(T: type HexOrInt, val: string): seq[string] =
  return @[]

proc notCmd(x: string): bool =
  if x.len == 0: return true

  # negative number
  if x.len >= 2 and
    x[0] == '-' and
    x[1].isDigit: return true

  # else
  x[0] != '-'

proc convertToNimStyle(cmds: openArray[string]): seq[string] =
  # convert something like '--key value' to '--key=value'
  var i = 0
  while i < cmds.len:
    if notCmd(cmds[i]) or i == cmds.len-1:
      result.add cmds[i]
      inc i
      continue

    if i < cmds.len and notCmd(cmds[i+1]):
      result.add cmds[i] & "=" & cmds[i+1]
      inc i
    else:
      result.add cmds[i]

    inc i

const
  Copyright = "Copyright (c) 2022 Status Research & Development GmbH"
  Version   = "Nimbus-t8n 0.2.2"

# force the compiler to instantiate T8NConf.load
# rather than have to export parseCmdArg
# because it will use wrong parseCmdArg from nimbus/config.nim
# when evmc_enabled
proc initT8NConf(cmdLine: openArray[string]): T8NConf =
  {.push warning[ProveInit]: off.}
  result = T8NConf.load(
    cmdLine.convertToNimStyle,
    version = Version,
    copyrightBanner = Version & "\n" & Copyright
  )
  {.pop.}

proc init*(_: type T8NConf, cmdLine = commandLineParams()): T8NConf =
  initT8NConf(cmdLine)
