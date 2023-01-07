# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handler Tables
## =========================
##

const
  noisy {.intdefine.}: int = 0
  # isNoisy {.used.} = noisy > 0
  isChatty {.used.} = noisy > 1

import
  strformat,
  ../../common/evmforks,
  ./op_codes,
  ./op_handlers/[oph_defs,
                 oph_arithmetic, oph_hash, oph_envinfo, oph_blockdata,
                 oph_memory, oph_push, oph_dup, oph_swap, oph_log,
                 oph_create, oph_call, oph_sysops, oph_function]

const
  allHandlersList = @[
    (vm2OpExecArithmetic, "Arithmetic"),
    (vm2OpExecHash,       "Hash"),
    (vm2OpExecEnvInfo,    "EnvInfo"),
    (vm2OpExecBlockData,  "BlockData"),
    (vm2OpExecMemory,     "Memory"),
    (vm2OpExecPush,       "Push"),
    (vm2OpExecPushZero,   "PushZero"),
    (vm2OpExecDup,        "Dup"),
    (vm2OpExecSwap,       "Swap"),
    (vm2OpExecLog,        "Log"),
    (vm2OpExecCreate,     "Create"),
    (vm2OpExecCall,       "Call"),
    (vm2OpExecSysOp,      "SysOp"),
    (vm2OpExecFunction,   "Function")]

# ------------------------------------------------------------------------------
# Helper
# ------------------------------------------------------------------------------

proc mkOpTable(selected: EVMFork): array[Op,Vm2OpExec] {.compileTime.} =

  # Collect selected <fork> entries
  for (subList,subName) in allHandlersList:
    for w in subList:
      if selected notin w.forks:
        continue
      # definitions must be mutually exclusive
      var prvInfo = result[w.opCode].info
      if prvInfo != "" or 0 < result[w.opCode].forks.card:
        echo &"*** {subName}: duplicate <{w.opCode}> entry: ",
              &"\"{prvInfo}\" vs. \"{w.info}\""
        doAssert result[w.opCode].info == ""
        doAssert result[w.opCode].forks.card == 0
      result[w.opCode] = w

  # Initialise unused entries
  for op in Op:
    if selected notin result[op].forks:
      result[op] = result[Invalid]
      result[op].opCode = op
      if op == Stop:
        result[op].name = "toBeReplacedByBreak"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

#const
#  vm2OpHandlers* = block:
#    var rc: array[Fork, array[Op, Vm2OpExec]]
#    for w in Fork:
#      rc[w] = w.mkOpTable
#    rc

type
  vmOpHandlersRec* = tuple
    name: string    ## Name (or ID) of op handler
    info: string    ## Some op handler info
    run:  Vm2OpFn   ## Executable handler

const
  # Pack handler record.
  #
  # Important:
  #   As of NIM 1.2.10, this mapping to another record is crucial for
  #
  #      vmOpHandlers[fork][op].run
  #
  #   to pick right function when <op> is a variable . Using
  #
  #      vm2OpHandlers[fork][op].exec.run
  #
  #   only works when <op> is a constant. There seems to be some optimisation
  #   that garbles the <exec> sub-structures elements <prep>, <run>, and <post>.
  #   Moreover, <post> is seen NULL under the debugger. It is untested yet
  #   under what circumstances the vm2OpHandlers[] matrix is set up correctly.
  #   Linearising/flattening the index has no effect here.
  #
  vmOpHandlers* = ## Op handler records matrix indexed `fork` x `op`
    block:
      var rc: array[EVMFork, array[Op, vmOpHandlersRec]]
      for fork in EVMFork:
        var tab = fork.mkOpTable
        for op in Op:
          rc[fork][op].name = tab[op].name
          rc[fork][op].info = tab[op].info
          rc[fork][op].run  = tab[op].exec.run
      rc

# ------------------------------------------------------------------------------
# Debugging ...
# ------------------------------------------------------------------------------

when isMainModule and isChatty:

  proc opHandlersRun(fork: EVMFork; op: Op; d: var Vm2Ctx) {.used.} =
    ## Given a particular `fork` and an `op`-code, run the associated handler
    vmOpHandlers[fork][op].run(d)

  proc opHandlersName(fork: EVMFork; op: Op): string {.used.} =
    ## Get name (or ID) of op handler
    vmOpHandlers[fork][op].name

  proc opHandlersInfo(fork: EVMFork; op: Op): string {.used.} =
    ## Get some op handler info
    vmOpHandlers[fork][op].info

  echo ">>> berlin[shl]:            ", FkBerlin.opHandlersInfo(Shl)
  echo ">>> berlin[push32]:         ", FkBerlin.opHandlersInfo(Push32)
  echo ">>> berlin[dup16]:          ", FkBerlin.opHandlersInfo(Dup16)
  echo ">>> berlin[swap16]:         ", FkBerlin.opHandlersInfo(Swap16)
  echo ">>> berlin[log4]:           ", FkBerlin.opHandlersInfo(Log4)

  echo ">>>       frontier[sstore]: ",       FkFrontier.opHandlersInfo(Sstore)
  echo ">>> constantinople[sstore]: ", FkConstantinople.opHandlersInfo(Sstore)
  echo ">>>         berlin[sstore]: ",         FkBerlin.opHandlersInfo(Sstore)
  echo ">>>          paris[sstore]: ",          FkParis.opHandlersInfo(Sstore)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
