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

import
  strformat,
  ./op_codes,
  ./op_handlers/[oph_defs,
                 oph_arithmetic, oph_hash, oph_envinfo, oph_blockdata,
                 oph_memory, oph_push, oph_dup, oph_swap, oph_log,
                 oph_create, oph_call, oph_sysops]

# ------------------------------------------------------------------------------
# Helper
# ------------------------------------------------------------------------------

proc importList(rc: var array[Op,Vm2OpExec];
                sel: Fork; list: seq[Vm2OpExec]; s: string) {.compileTime.} =
  for w in list:
    if sel notin w.forks:
      continue
    var oInf = rc[w.opCode].info
    if oInf != "" or 0 < rc[w.opCode].forks.card:
      echo &"*** {s}: duplicate <{w.opCode}> entry: \"{oInf}\" vs. \"{w.info}\""
      doAssert rc[w.opCode].info == ""
      doAssert rc[w.opCode].forks.card == 0
    rc[w.opCode] = w


proc mkOpTable(select: Fork): array[Op,Vm2OpExec] {.compileTime.} =
  result.importList(select, vm2OpExecArithmetic, "Arithmetic")
  result.importList(select, vm2OpExecHash,       "Hash")
  result.importList(select, vm2OpExecEnvInfo,    "EnvInfo")
  result.importList(select, vm2OpExecBlockData,  "BlockData")
  result.importList(select, vm2OpExecMemory,     "Memory")
  result.importList(select, vm2OpExecPush,       "Push")
  result.importList(select, vm2OpExecDup,        "Dup")
  result.importList(select, vm2OpExecSwap,       "Swap")
  result.importList(select, vm2OpExecLog,        "Log")
  result.importList(select, vm2OpExecCreate,     "Create")
  result.importList(select, vm2OpExecCall,       "Call")
  result.importList(select, vm2OpExecSysOp,      "SysOp")

  for op in Op:
    if select notin result[op].forks:
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
  hdlRec = tuple
    name: string
    info: string
    run:  Vm2OpFn

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
  vmOpHandlers = block:
    var rc: array[Fork, array[Op, hdlRec]]
    for fork in Fork:
      var tab = fork.mkOpTable
      for op in Op:
        rc[fork][op].name = tab[op].name
        rc[fork][op].info = tab[op].info
        rc[fork][op].run  = tab[op].exec.run
    rc

proc opHandlersRun*(fork: Fork; op: Op; d: Vm2Ctx) {.inline.} =
  ## Given a particular `fork` and an `op`-code, run the associated handler
  vmOpHandlers[fork][op].run(d)

proc opHandlersName*(fork: Fork; op: Op): string =
  ## Get name (or ID) of op handler
  vmOpHandlers[fork][op].name

proc opHandlersInfo*(fork: Fork; op: Op): string =
  ## Get some op handler info
  vmOpHandlers[fork][op].info

# ------------------------------------------------------------------------------
# Debugging ...
# ------------------------------------------------------------------------------

when isMainModule and isNoisy:
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
