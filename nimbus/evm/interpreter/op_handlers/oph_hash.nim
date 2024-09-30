# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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

{.push raises: [].}

import
  ../../../constants,
  ../../evm_errors,
  ../../computation,
  ../../memory,
  ../../stack,
  ../gas_costs,
  ../op_codes,
  ./oph_defs,
  eth/common

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

proc sha3Op(cpt: VmCpt): EvmResultVoid =
  ## 0x20, Compute Keccak-256 hash.
  ? cpt.stack.lsCheck(2)
  let
    pos = cpt.stack.lsPeekSafeInt(^1)
    len = cpt.stack.lsPeekSafeInt(^2)
  cpt.stack.lsShrink(1)

  if pos < 0 or len < 0 or pos > 2147483648'i64:
    return err(opErr(OutOfBounds))

  ? cpt.opcodeGasCost(Op.Sha3,
    cpt.gasCosts[Op.Sha3].m_handler(cpt.memory.len, pos, len),
      reason = "SHA3: word gas cost")

  cpt.memory.extend(pos, len)

  let endRange = min(pos + len, cpt.memory.len) - 1
  if endRange == -1 or pos >= cpt.memory.len:
    cpt.stack.lsTop(EMPTY_SHA3)
  else:
    cpt.stack.lsTop keccak256 cpt.memory.bytes.toOpenArray(pos, endRange)
  ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecHash*: seq[VmOpExec] = @[

    (opCode: Op.Sha3,     ## 0x20, Keccak-256
     forks: VmOpAllForks,
     name: "sha3",
     info: "Compute Keccak-256 hash",
     exec: sha3Op)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
