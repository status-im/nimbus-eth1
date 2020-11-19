# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import macros, strutils, os, unittest2, osproc
import threadpool

# AppVeyor may go out of memory with the default of 4
setMinPoolSize(2)

proc executeMyself(numModules: int, names: openArray[string]): int =
  let appName = getAppFilename()
  for i in 0..<numModules:
    let execResult = execCmd(appName & " " & $i)
    if execResult != 0:
      stderr.writeLine("subtest no: " & $i & " failed: " & names[i])
    result = result or execResult

proc getImportStmt(stmtList: NimNode): NimNode =
  result = stmtList[0]
  result.expectKind nnkImportStmt

proc ofStmt(idx: int, singleModule: NimNode): NimNode =
  # remove the "test_" prefix
  let moduleName = normalize(singleModule.toStrLit.strVal).substr(4)
  let moduleMain = newIdentNode(moduleName & "Main")

  # construct `of` branch
  # of idx: moduleMain()
  result = nnkOfBranch.newTree(
    newLit(idx),
    newCall(moduleMain)
  )

proc toModuleNames(importStmt: NimNode): NimNode =
  result = nnkBracket.newTree
  for singleModule in importStmt:
    let x = normalize(singleModule.toStrLit.strVal)
    result.add newLit(x)

macro cliBuilder(stmtList: typed): untyped =
  let importStmt = stmtList.getImportStmt
  let moduleCount = importStmt.len
  let moduleNames = importStmt.toModuleNames

  # case paramStr(1).parseInt
  var caseStmt = nnkCaseStmt.newTree(
    quote do: paramStr(1).parseInt
  )

  # of 0: codeStreamMain()
  # of 1: gasMeterMain()
  # of 2: memoryMain()
  # ...
  for idx, singleModule in importStmt:
    caseStmt.add ofStmt(idx, singleModule)

  # else:
  #   echo "invalid argument"
  caseStmt.add nnkElse.newTree(
    quote do: echo "invalid argument"
  )

  result = quote do:
    if paramCount() == 0:
      const names = `moduleNames`
      quit(executeMyself(`moduleCount`, names))
    else:
      disableParamFiltering()
      `caseStmt`

# if you want to add new test module(s)
# make sure you define an entry poin
# e.g.
# proc mytestMain*() =
#   # put anything you want here
# and then give it a name `test_mytest.nim`
# the `mytest` part should match between
# the proc name and the module name

# if this executable called without any params
# it will execute each of the test by executing itself
# repeatedly until all sub-tests are executed.
# you can execute the sub-test by a number start from zero.

{. warning[UnusedImport]:off .}

cliBuilder:
  import  ./test_code_stream,
          ./test_gas_meter,
          ./test_memory,
          ./test_stack,
          ./test_genesis,
          ./test_vm_json,
          ./test_precompiles,
          ./test_generalstate_json,
          ./test_tracer_json,
          ./test_persistblock_json,
          #./test_rpc, # it crash if we combine it here
          ./test_op_arith,
          ./test_op_bit,
          ./test_op_env,
          ./test_op_memory,
          ./test_op_misc,
          ./test_op_custom,
          ./test_state_db,
          ./test_difficulty,
          ./test_transaction_json,
          ./test_blockchain_json,
          ./test_forkid,
          ../stateless/test_witness_keys,
          ../stateless/test_block_witness,
          ../stateless/test_witness_json,
          ./test_misc
