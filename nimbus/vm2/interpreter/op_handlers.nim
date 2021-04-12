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
  ./op_codes,
  ./op_handlers/[oph_defs,
                 oph_arithmetic, oph_hash,
                 oph_sysops]

# ------------------------------------------------------------------------------
# Helper
# ------------------------------------------------------------------------------

const
  allForksTable = block:
      var rc: array[Op, Vm2OpExec]

      for w in vm2OpExecArithmetic:
        rc[w.opCode] = w

      for w in vm2OpExecHash:
        rc[w.opCode] = w

      for w in vm2OpExecSysOP:
        rc[w.opCode] = w

      rc

proc mkOpTable(select: Fork): array[Op, Vm2OpExec] {.compileTime.} =
  for op in Op:
    var w = allForksTable[op]
    if FkFrontier in w.forks:
      result[op] = w
    else:
      result[op] = allForksTable[Invalid]
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

  vm2OpTabFrontier*       = vm2OpHandlers[FkFrontier]
  vm2OpTabHomestead*      = vm2OpHandlers[FkHomestead]
  vm2OpTabTangerine*      = vm2OpHandlers[FkTangerine]
  vm2OpTabSpurious*       = vm2OpHandlers[FkSpurious]
  vm2OpTabByzantium*      = vm2OpHandlers[FkByzantium]
  vm2OpTabConstantinople* = vm2OpHandlers[FkConstantinople]
  vm2OpTabPetersburg*     = vm2OpHandlers[FkPetersburg]
  vm2OpTabIstanbul*       = vm2OpHandlers[FkIstanbul]
  vm2OpTabBerlin*         = vm2OpHandlers[FkBerlin]

# ------------------------------------------------------------------------------
# Debugging ...
# ------------------------------------------------------------------------------

when isMainModule and isNoisy:
  var dummy = 0
  proc gdbBPSink() =
    dummy.inc

  const
    a = vm2OpTabFrontier
    b = a[Stop].info

  gdbBPSink()
  echo ">>> ", b

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
