# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import macros, strutils, os, unittest, osproc

proc executeMyself(numModules: int) =
  let appName = getAppFilename()
  for i in 0..<numModules:
    discard execCmd appName & " " & $i

macro cliBuilder(stmtList: typed): untyped =
  let importStmt = stmtList[0]
  importStmt.expectKind nnkImportStmt
  let moduleCount = importStmt.len

  var caseStmt = newNimNode(nnkCaseStmt)
  caseStmt.add quote do: paramStr(1).parseInt

  for idx, singleModule in importStmt:
    # remove the "test_" prefix
    let moduleName = normalize(singleModule.toStrLit.strVal).substr(4)
    let moduleMain = newIdentNode(moduleName & "Main")
    # construct `of` branch
    let branchNode = newNimNode(nnkOfBranch)
    branchNode.add newIntLitNode(idx)
    branchNode.add newCall(moduleMain)
    caseStmt.add branchNode

  var elseBranch = newNimNode(nnkElse)
  elseBranch.add quote do:
    echo "invalid argument"
  caseStmt.add elseBranch

  result = quote do:
    if paramCount() == 0:
      executeMyself `moduleCount`
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
          ./test_transaction_json
