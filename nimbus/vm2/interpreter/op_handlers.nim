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
  isNoisy {.used.} = noisy > 0

  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  strformat,
  ./forks_list,
  ./op_codes,
  ./op_handlers/[oph_defs,
                 oph_arithmetic, oph_hash, oph_envinfo, oph_blockdata,
                 oph_memory, oph_push, oph_dup, oph_swap, oph_log,
                 oph_create, oph_call, oph_sysops]

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  const
    useExecCreate = vm2OpExecCreate
    useExecCall = vm2OpExecCall

else:
  # note: oph_create/call are always imported to check for syntactic corretness,
  #       at the moment, it would not match the other handler lists due to the
  #       fake Computation object definition.
  const
    useExecCreate: seq[Vm2OpExec] = @[]
    useExecCall: seq[Vm2OpExec] = @[]

    ignoreVm2OpExecCreate {.used.} = vm2OpExecCreate
    ignoreVm2OpExecCall  {.used.} = vm2OpExecCall
  {.warning: "*** Ignoring tables from <oph_create> and <oph_call>".}

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

const
  allHandlersList = @[
    (vm2OpExecArithmetic, "Arithmetic"),
    (vm2OpExecHash,       "Hash"),
    (vm2OpExecEnvInfo,    "EnvInfo"),
    (vm2OpExecBlockData,  "BlockData"),
    (vm2OpExecMemory,     "Memory"),
    (vm2OpExecPush,       "Push"),
    (vm2OpExecDup,        "Dup"),
    (vm2OpExecSwap,       "Swap"),
    (vm2OpExecLog,        "Log"),
    (useExecCreate,       "Create"),
    (useExecCall,         "Call"),
    (vm2OpExecSysOp,      "SysOp")]

# ------------------------------------------------------------------------------
# Helper
# ------------------------------------------------------------------------------

proc mkOpTable(selected: Fork): array[Op,Vm2OpExec] {.compileTime.} =

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
      var rc: array[Fork, array[Op, vmOpHandlersRec]]
      for fork in Fork:
        var tab = fork.mkOpTable
        for op in Op:
          rc[fork][op].name = tab[op].name
          rc[fork][op].info = tab[op].info
          rc[fork][op].run  = tab[op].exec.run
      rc

# ------------------------------------------------------------------------------
# Debugging ...
# ------------------------------------------------------------------------------

when isMainModule and isNoisy:

  proc opHandlersRun(fork: Fork; op: Op; d: var Vm2Ctx) {.used.} =
    ## Given a particular `fork` and an `op`-code, run the associated handler
    vmOpHandlers[fork][op].run(d)

  proc opHandlersName(fork: Fork; op: Op): string {.used.} =
    ## Get name (or ID) of op handler
    vmOpHandlers[fork][op].name

  proc opHandlersInfo(fork: Fork; op: Op): string {.used.} =
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
