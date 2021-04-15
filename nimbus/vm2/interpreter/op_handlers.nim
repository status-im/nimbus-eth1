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
                 oph_sysops]

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
  #result.importList(select, vm2OpExecCreate,     "Create")
  #result.importList(select, vm2OpExecCall,       "Call")
  result.importList(select, vm2OpExecSysOp,      "SysOp")

  for op in Op:
    if select notin result[op].forks:
      result[op] = result[Invalid]
      result[op].opCode = op

# ------------------------------------------------------------------------------
# Public handler tables
# ------------------------------------------------------------------------------

const
  vm2OpHandlers* = block:
    var rc: array[Fork, array[Op, Vm2OpExec]]
    for w in Fork:
      rc[w] = w.mkOpTable
    rc

  # vm2OpTabFrontier*       = vm2OpHandlers[FkFrontier]
  # vm2OpTabHomestead*      = vm2OpHandlers[FkHomestead]
  # vm2OpTabTangerine*      = vm2OpHandlers[FkTangerine]
  # vm2OpTabSpurious*       = vm2OpHandlers[FkSpurious]
  # vm2OpTabByzantium*      = vm2OpHandlers[FkByzantium]
  # vm2OpTabConstantinople* = vm2OpHandlers[FkConstantinople]
  # vm2OpTabPetersburg*     = vm2OpHandlers[FkPetersburg]
  # vm2OpTabIstanbul*       = vm2OpHandlers[FkIstanbul]
  # vm2OpTabBerlin*         = vm2OpHandlers[FkBerlin]

# ------------------------------------------------------------------------------
# Debugging ...
# ------------------------------------------------------------------------------

when isMainModule and isNoisy:
  var dummy = 0
  proc gdbBPSink() =
    dummy.inc

  gdbBPSink()
  echo ">>> berlin[shl]:            ",
        vm2OpHandlers[FkBerlin][Shl].info

  echo ">>> berlin[push32]:         ",
        vm2OpHandlers[FkBerlin][Push32].info

  echo ">>> berlin[dup16]:          ",
        vm2OpHandlers[FkBerlin][Dup16].info

  echo ">>> berlin[swap16]:         ",
        vm2OpHandlers[FkBerlin][Swap16].info

  echo ">>> berlin[log4]:           ",
        vm2OpHandlers[FkBerlin][Log4].info

  echo ">>> frontier[sstore]:       ",
        vm2OpHandlers[FkFrontier][Sstore].info

  echo ">>> constantinople[sstore]: ",
        vm2OpHandlers[FkConstantinople][Sstore].info

  echo ">>> berlin[sstore]:         ",
        vm2OpHandlers[FkBerlin][Sstore].info

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
