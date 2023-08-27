# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Hashes
## ===========================
##

import
  ../../../constants,
  ../../../errors,
  ../../computation,
  ../../memory,
  ../../stack,
  ../gas_costs,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  eth/common

{.push raises: [CatchableError].} # basically the annotation type of a `Vm2OpFn`

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  sha3Op: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x20, Compute Keccak-256 hash.
    let (startPos, length) = k.cpt.stack.popInt(2)

    let (pos, len) = (startPos.safeInt, length.safeInt)
    if pos < 0 or len < 0 or pos > 2147483648'i64:
      raise newException(OutOfBoundsRead, "Out of bounds memory access")

    k.cpt.opcodeGastCost(Op.Sha3,
      k.cpt.gasCosts[Op.Sha3].m_handler(k.cpt.memory.len, pos, len),
      reason = "SHA3: word gas cost")

    k.cpt.memory.extend(pos, len)

    let endRange = min(pos + len, k.cpt.memory.len) - 1
    if endRange == -1 or pos >= k.cpt.memory.len:
      k.cpt.stack.push(EMPTY_SHA3)
    else:
      k.cpt.stack.push:
        keccakHash k.cpt.memory.bytes.toOpenArray(pos, endRange)

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecHash*: seq[Vm2OpExec] = @[

    (opCode: Op.Sha3,     ## 0x20, Keccak-256
     forks: Vm2OpAllForks,
     name: "sha3",
     info: "Compute Keccak-256 hash",
     exec: (prep: vm2OpIgnore,
            run:  sha3Op,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
