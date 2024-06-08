# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Swap Operations
## ====================================
##

{.push raises: [].}

import
  ../../evm_errors,
  ../../stack,
  ../op_codes,
  ./oph_defs,
  ./oph_gen_handlers,
  sequtils

# ------------------------------------------------------------------------------
# Private, names & settings
# ------------------------------------------------------------------------------

proc fnName(n: int): string {.compileTime.} =
  "swap" & $n & "Op"

proc opName(n: int): string {.compileTime.} =
  "Swap" & $n

proc fnInfo(n: int): string {.compileTime.} =
  var blurb = case n+1
              of 1: "first"
              of 2: "second"
              of 3: "third"
              else: $(n+1) & "th"
  "Exchange first and " & blurb & " stack items"


func swapImpl(k: var Vm2Ctx; n: int): EvmResultVoid =
  k.cpt.stack.swap(n)

const
  inxRange = toSeq(1 .. 16)

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

genOphHandlers fnName, fnInfo, inxRange, swapImpl

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

genOphList fnName, fnInfo, inxRange, "vm2OpExecSwap", opName

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
