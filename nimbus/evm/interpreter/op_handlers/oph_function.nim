# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Function Operations
## ======================================
##

import
  ../../../errors,
  ../../code_stream,
  ../../stack,
  ../../types,
  ../op_codes,
  ./oph_defs

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  callfOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0xb0, Call a function.
    let
      idx = k.cpt.code.readInt16()
      typ = k.cpt.code.getType(idx)

    if k.cpt.stack.len + typ.maxStackHeight.int >= 1024:
      raise newException(
        StackDepthError, "CallF stack overflow")

    k.cpt.returnStack.add ReturnContext(
      section    : k.cpt.code.section,
      pc         : k.cpt.code.pc,
      stackHeight: k.cpt.stack.len - typ.input.int
    )

    k.cpt.code.setSection(idx)
    k.cpt.code.pc = 0

  retfOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x50, Return from a function.
    let ctx = k.cpt.returnStack.pop()
    k.cpt.code.setSection(ctx.section)
    k.cpt.code.pc = ctx.pc

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecFunction*: seq[Vm2OpExec] = @[

    (opCode: CallF,    ## 0xb0, Call a function
     forks: Vm2OpEOFAndLater,
     name: "CallF",
     info: "Create a new account with associated code",
     exec: (prep: vm2OpIgnore,
            run: callfOp,
            post: vm2OpIgnore)),

    (opCode: RetF,     ## 0xb1, Return from a function
     forks: Vm2OpEOFAndLater,
     name: "RetF",
     info: "Behaves identically to CREATE, except using keccak256",
     exec: (prep: vm2OpIgnore,
            run: retfOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
