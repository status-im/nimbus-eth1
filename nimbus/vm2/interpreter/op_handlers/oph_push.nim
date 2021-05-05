# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
  ../../../errors,
  ../../code_stream,
  ../../stack,
  ../op_codes,
  ./oph_defs,
  ./oph_gen_handlers,
  sequtils,
  stint,
  strformat

{.push raises: [Defect,VMError,ValidationError,ValueError].}

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
