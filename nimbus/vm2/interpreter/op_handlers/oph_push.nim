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


const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ./oph_defs,
  ./oph_helpers,
  sequtils,
  strformat,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../code_stream,
    ../../stack

else:
  # function stubs from stack.nim (to satisfy compiler logic)
  proc push[T](x: Stack; n: T) = discard

  # function stubs from code_stream.nim
  proc readVmWord(c: var CodeStream, n: int): UInt256 = 0.u256

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

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


proc pushImpl(k: Vm2Ctx; n: int) =
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
