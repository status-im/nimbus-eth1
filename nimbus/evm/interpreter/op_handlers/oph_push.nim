# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Push Operations
## ====================================
##

import
  std/[strformat, sequtils],
  ../../code_stream,
  ../../stack,
  ../op_codes,
  ./oph_defs,
  ./oph_gen_handlers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc fnName(n: int): string {.compileTime.} =
  &"push{n}Op"

proc opName(n: int): string {.compileTime.} =
  &"Push{n}"

proc fnInfo(n: int): string {.compileTime.} =
  var blurb = case n
              of 1: "byte"
              else: &"{n} bytes"
  &"Push {blurb} on the stack"


proc pushImpl(k: var Vm2Ctx; n: int) =
  k.cpt.stack.push:
    k.cpt.code.readVmWord(n)

const
  inxRange = toSeq(1 .. 32)

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

genOphHandlers fnName, fnInfo, inxRange, pushImpl

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

genOphList fnName, fnInfo, inxRange, "vm2OpExecPush", opName


# Push0 needs to be slightly different because it's only available after
# Shanghai (EIP-3855). But it still seems like it belongs in this file.
# (Alternatively, we could make genOphList accept some more information
# about which opcodes are for which forks, but that seems uglier than
# just adding Push0 here as a special case.)

const
  push0Op: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x5f, push 0 onto the stack
    k.cpt.stack.push(0)
  
  vm2OpExecPushZero*: seq[Vm2OpExec] = @[

    (opCode: Push0,       ## 0x5f, push 0 onto the stack
     forks: Vm2OpShanghaiAndLater,
     name: "Push0",
     info: "Push 0 on the stack",
     exec: (prep: vm2OpIgnore,
            run:  push0Op,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
