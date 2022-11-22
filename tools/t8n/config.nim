import
  std/[options, os, strutils],
  confutils,
  ./types

export
  options

func combineForks(): string =
  for x in low(TestFork)..high(TestFork):
    result.add "- " & $x & "\n"

const
  availableForks = combineForks()

type
  HexOrInt* = distinct uint64

  T8NConf* = object of RootObj
    traceEnabled* {.
      desc: "Output full trace logs to files trace-<txIndex>-<txhash>.jsonl"
      defaultValue: false
      name: "trace" }: bool

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
      desc: "Mining reward. Set to 0 to disable"
      defaultValue: 0
      name: "state.reward" }: HexOrInt

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

proc parseCmdArg*(T: type HexOrInt, p: TaintedString): T =
  if startsWith(p.string, "0x"):
    parseHexInt(p.string).T
  else:
    parseInt(p.string).T

proc completeCmdArg*(T: type HexOrInt, val: TaintedString): seq[string] =
  return @[]

proc notCmd(x: string): bool =
  if x.len == 0: return true
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
  Version   = "Nimbus-t8n 0.1.0"

proc init*(_: type T8NConf, cmdLine = commandLineParams()): T8NConf =
  {.push warning[ProveInit]: off.}
  result = T8NConf.load(
    cmdLine.convertToNimStyle,
    version = Version,
    copyrightBanner = Version & "\n" & Copyright
  )
  {.pop.}
