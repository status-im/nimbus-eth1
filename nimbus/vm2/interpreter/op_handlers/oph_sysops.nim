# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: System Operations
## ======================================
##

import
  ../op_codes, ./oph_defs, ../../../errors.nim

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

const
  invalidOp: Vm2OpFn =
    proc(k: Vm2Ctx) {.gcsafe.} =
      raise newException(InvalidInstruction,
                         "Invalid instruction, received an opcode " &
                           "not implemented in the current fork.")

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecSysOP*: seq[Vm2OpExec] = @[

    (opCode: Invalid,          ## 0xfe, invalid instruction.
     forks: Vm2OpAllForks,
     info: "Designated invalid instruction",
     exec: (prep: vm2OpIgnore,
            run: invalidOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
