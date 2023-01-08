# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, osproc, strutils, json, tables],
  unittest2,
  "."/[types]

type
  T8nInput = object
    inAlloc : string
    inTxs   : string
    inEnv   : string
    stFork  : string
    stReward: string

  T8nOutput = object
    alloc : bool
    result: bool
    body  : bool
    trace : bool

  TestSpec = object
    name       : string
    base       : string
    input      : T8nInput
    output     : T8nOutput
    expExitCode: int
    expOut     : string

  JsonComparator = object
    path: string
    error: string

proc t8nInput(alloc, txs, env, fork, reward: string): T8nInput =
  T8nInput(
    inAlloc : alloc,
    inTxs   : txs,
    inEnv   : env,
    stFork  : fork,
    stReward: reward
  )

proc get(opt: T8nInput, base  : string): string =
  result.add(" --input.alloc " & (base / opt.inAlloc))
  result.add(" --input.txs "   & (base / opt.inTxs))
  result.add(" --input.env "   & (base / opt.inEnv))
  result.add(" --state.fork "  & opt.stFork)
  if opt.stReward.len > 0:
    result.add(" --state.reward " & opt.stReward)

proc get(opt: T8nOutput): string =
  if opt.alloc:
    result.add(" --output.alloc stdout")
  else:
    result.add(" --output.alloc")

  if opt.result:
    result.add(" --output.result stdout")
  else:
    result.add(" --output.result")

  if opt.body:
    result.add(" --output.body stdout")
  else:
    result.add(" --output.body")

  if opt.trace:
    result.add(" --trace stdout")

template exit(jsc: var JsonComparator, msg: string) =
  jsc.path = path
  jsc.error = msg
  return false

proc cmp(jsc: var JsonComparator; a, b: JsonNode, path: string): bool =
  ## Check two nodes for equality
  if a.isNil:
    if b.isNil: return true
    jsc.exit("A nil, but B not nil")
  elif b.isNil:
    jsc.exit("A not nil, but B nil")
  elif a.kind != b.kind:
    jsc.exit("A($1) != B($2)" % [$a.kind, $b.kind])
  else:
    result = true
    case a.kind
    of JString:
      if a.str != b.str:
        jsc.exit("STRING A($1) != B($2)" % [a.str, b.str])
    of JInt:
      if a.num != b.num:
        jsc.exit("INT A($1) != B($2)" % [$a.num, $b.num])
    of JFloat:
      if a.fnum != b.fnum:
        jsc.exit("FLOAT A($1) != B($2)" % [$a.fnum, $b.fnum])
    of JBool:
      if a.bval != b.bval:
        jsc.exit("BOOL A($1) != B($2)" % [$a.bval, $b.bval])
    of JNull:
      result = true
    of JArray:
      for i, x in a.elems:
        if not jsc.cmp(x, b.elems[i], path & "/" & $i):
          return false
    of JObject:
      # we cannot use OrderedTable's equality here as
      # the order does not matter for equality here.
      if a.fields.len != b.fields.len:
        jsc.exit("OBJ LEN A($1) != B($2)" % [$a.fields.len, $b.fields.len])
      for key, val in a.fields:
        if not b.fields.hasKey(key):
          jsc.exit("OBJ FIELD A($1) != B(none)" % [key])
        if not jsc.cmp(val, b.fields[key], path & "/" & key):
          return false

proc notRejectedError(path: string): bool =
  # we only check error status, and not the error message
  # because each implementation can have different error
  # message
  not (path.startsWith("root/result/rejected/") and
    path.endsWith("/error"))

proc runTest(appDir: string, spec: TestSpec): bool =
  let base = appDir / spec.base
  let args = spec.input.get(base) & spec.output.get()
  let cmd  = appDir / "t8n" & args
  let (res, exitCode) = execCmdEx(cmd)

  if exitCode != spec.expExitCode:
    echo "test $1: wrong exit code, have $2, want $3" %
      [spec.name, $exitCode, $spec.expExitCode]
    echo res
    return false

  if spec.expOut.len > 0:
    if spec.expOut.endsWith(".json"):
      let path = base / spec.expOut
      let want = json.parseFile(path)
      let have = json.parseJson(res)
      var jsc = JsonComparator()
      if not jsc.cmp(want, have, "root") and notRejectedError(jsc.path):
        echo "test $1: output wrong, have \n$2\nwant\n$3\n" %
          [spec.name, have.pretty, want.pretty]
        echo "path: $1, error: $2" %
          [jsc.path, jsc.error]
        return false
    else:
      # compare as regular text
      let path = base / spec.expOut
      let want = readFile(path)
      if want.replace("\x0D\x0A", "\n") != res:
        echo "test $1: output wrong, have \n$2\nwant\n$3\n" %
          [spec.name, res, want]
        return false
  return true

const
  testSpec = [
    TestSpec(
      name  : "Test exit (3) on bad config",
      base  : "testdata/1",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Frontier+1346", "",
      ),
      output: T8nOutput(alloc: true, result: true),
      expExitCode: ErrorConfig.int,
    ),
    TestSpec(
      name  : "baseline test",
      base  : "testdata/1",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Byzantium", "",
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "blockhash test",
      base  : "testdata/3",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", ""
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json"
    ),
    TestSpec(
      name  : "missing blockhash test",
      base  : "testdata/4",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", "",
      ),
      output: T8nOutput(alloc: true, result: true),
      expExitCode: ErrorMissingBlockhash.int,
    ),
    TestSpec(
      name  : "Uncle test",
      base  : "testdata/5",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Byzantium", "0x80",
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Sign json transactions",
      base  : "testdata/13",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "London", "",
      ),
      output: T8nOutput(body: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Already signed transactions",
      base  : "testdata/13",
      input : t8nInput(
        "alloc.json", "signed_txs.rlp", "env.json", "London", "",
      ),
      output: T8nOutput(result: true),
      expOut: "exp2.json",
    ),
    TestSpec(
      name  : "Difficulty calculation - no uncles",
      base  : "testdata/14",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "London", "",
      ),
      output: T8nOutput(result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Difficulty calculation - with uncles",
      base  : "testdata/14",
      input : t8nInput(
        "alloc.json", "txs.json", "env.uncles.json", "London", "",
      ),
      output: T8nOutput(result: true),
      expOut: "exp2.json",
    ),
    TestSpec(
      name  : "Difficulty calculation - with ommers + Berlin",
      base  : "testdata/14",
      input : t8nInput(
        "alloc.json", "txs.json", "env.uncles.json", "Berlin", "",
      ),
      output: T8nOutput(result: true),
      expOut: "exp_berlin.json",
    ),
    TestSpec(
      name  : "Difficulty calculation on london",
      base  : "testdata/19",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "London", "",
      ),
      output: T8nOutput(result: true),
      expOut: "exp_london.json",
    ),
    TestSpec(
      name  : "Difficulty calculation on arrow glacier",
      base  : "testdata/19",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "ArrowGlacier", "",
      ),
      output: T8nOutput(result: true),
      expOut: "exp_arrowglacier.json",
    ),
    TestSpec(
      name  : "Difficulty calculation on gray glacier",
      base  : "testdata/19",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "GrayGlacier", "",
      ),
      output: T8nOutput(result: true),
      expOut: "exp_grayglacier.json",
    ),
    TestSpec(
      name  : "Sign unprotected (pre-EIP155) transaction",
      base  : "testdata/23",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", "",
      ),
      output: T8nOutput(result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Test post-merge transition",
      base  : "testdata/24",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Merge", "",
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Test post-merge transition where input is missing random",
      base  : "testdata/24",
      input : t8nInput(
        "alloc.json", "txs.json", "env-missingrandom.json", "Merge", "",
      ),
      output: T8nOutput(alloc: false, result: false),
      expExitCode: ErrorConfig.int,
    ),
    TestSpec(
      name  : "Test state-reward -1",
      base  : "testdata/3",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", "-1"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "0-touch reward on pre EIP150 networks -1(txs.rlp)",
      base  : "testdata/00-501",
      input : t8nInput(
        "alloc.json", "txs.rlp", "env.json", "EIP150", "-1"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "0-touch reward on pre EIP150 networks(txs.rlp)",
      base  : "testdata/00-502",
      input : t8nInput(
        "alloc.json", "txs.rlp", "env.json", "EIP150", ""
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "0-touch reward on pre EIP150 networks(txs.json)",
      base  : "testdata/00-502",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "EIP150", ""
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "calculate basefee from parentBaseFee -1",
      base  : "testdata/00-503",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "London", "-1"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "calculate basefee from parentBaseFee",
      base  : "testdata/00-504",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "London", ""
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "BLOCKHASH opcode -1",
      base  : "testdata/00-505",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "London", "-1"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "BLOCKHASH opcode",
      base  : "testdata/00-506",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "London", ""
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "testOpcode 40 Berlin",
      base  : "testdata/00-507",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", "2000000000000000000"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "suicideCoinbaseState Berlin",
      base  : "testdata/00-508",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", "2000000000000000000"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "BLOCKHASH Bounds",
      base  : "testdata/00-509",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", "2000000000000000000"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Suicides Mixing Coinbase",
      base  : "testdata/00-510",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", "2000000000000000000"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Legacy Byzantium State Clearing",
      base  : "testdata/00-511",
      input : t8nInput(
        "alloc.json", "txs.rlp", "env.json", "Byzantium", "-1"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Test withdrawals transition",
      base  : "testdata/26",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Shanghai", ""
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Revert In Create In Init Create2",
      base  : "testdata/00-512",
      input : t8nInput(
        "alloc.json", "txs.rlp", "env.json", "Berlin", "0"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Revert In Create In Init",
      base  : "testdata/00-513",
      input : t8nInput(
        "alloc.json", "txs.rlp", "env.json", "Berlin", "0"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Init collision 3",
      base  : "testdata/00-514",
      input : t8nInput(
        "alloc.json", "txs.rlp", "env.json", "Berlin", "0"
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Malicious withdrawals address",
      base  : "testdata/00-515",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Shanghai", "",
      ),
      output: T8nOutput(alloc: false, result: false),
      expExitCode: ErrorJson.int,
    ),
    TestSpec(
      name  : "GasUsedHigherThanBlockGasLimitButNotWithRefundsSuicideLast_Frontier",
      base  : "testdata/00-516",
      input : t8nInput(
        "alloc.json", "txs.rlp", "env.json", "Frontier", "5000000000000000000",
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Cancun optional fields",
      base  : "testdata/00-517",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Cancun", "",
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Blobhash list bounds",
      base  : "testdata/00-518",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Cancun", "",
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
<<<<<<< HEAD
      name  : "EVM tracer nil stack crash bug",
      base  : "testdata/00-519",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Shanghai", "0",
      ),
      output: T8nOutput(trace: true),
      expOut: "exp.txt",
    ),
    TestSpec(
      name  : "EVM tracer wrong order for CALL family opcodes",
      base  : "testdata/00-520",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Merge", "0",
      ),
      output: T8nOutput(trace: true, result: true),
      expOut: "exp.txt",
    ),
    TestSpec(
      name  : "EVM tracer CALL family exception",
      base  : "testdata/00-521",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Shanghai", "0",
      ),
      output: T8nOutput(trace: true, result: true),
      expOut: "exp.txt",
    ),
    TestSpec(
      name  : "Cancun tests",
      base  : "testdata/28",
      input : t8nInput(
        "alloc.json", "txs.rlp", "env.json", "Cancun", "",
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "More cancun tests",
      base  : "/testdata/29",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Cancun", "",
      ),
      output: T8nOutput(alloc: true, result: true),
      expOut: "exp.json",
    ),
    TestSpec(
      name  : "Trace EIP-2929 Balance, Sload, ExtCodeSize, ExtCodeHash",
      base  : "testdata/00-522",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Berlin", "0",
      ),
      output: T8nOutput(trace: true, result: true),
      expOut: "exp.txt",
    ),
    TestSpec(
      name  : "Trace Post EIP-2929 Balance, Sload, ExtCodeSize, ExtCodeHash",
      base  : "testdata/00-522",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "London", "0",
      ),
      output: T8nOutput(trace: true, result: true),
      expOut: "exp.txt",
    ),
    TestSpec(
      name  : "Trace Pre EIP-2929 Balance, Sload, ExtCodeSize, ExtCodeHash",
      base  : "testdata/00-522",
      input : t8nInput(
        "alloc.json", "txs.json", "env.json", "Istanbul", "0",
      ),
      output: T8nOutput(trace: true, result: true),
      expOut: "istanbul.txt",
    ),
    TestSpec(
      name: "Validate pre-allocated EOF code",
      base: "testdata/01-501",
      input: t8nInput(
        "alloc.json", "txs.json", "env.json", "Cancun", "",
      ),
      output: T8nOutput(alloc: true, result: false),
      expExitCode: 3,
    ),
  ]

proc main() =
  suite "Transition tool (t8n) test suite":
    let appDir = getAppDir()
    for x in testSpec:
      test x.name:
        check runTest(appDir, x)

when isMainModule:
  main()
