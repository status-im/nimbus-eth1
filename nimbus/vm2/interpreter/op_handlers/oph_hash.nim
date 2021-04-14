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

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ./oph_defs,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../constants,
    ../../stack,
    ../../v2computation,
    ../../v2memory,
    ../gas_meter,
    ../utils/v2utils_numeric,
    ../v2gas_costs,
    eth/common,
    nimcrypto

else:
  import macros

  var blindGasCosts: array[Op,int]

  # copied from stack.nim
  macro genTupleType(len: static[int], elemType: untyped): untyped =
    result = nnkTupleConstr.newNimNode()
    for i in 0 ..< len: result.add(elemType)

  # function stubs from stack.nim (to satisfy compiler logic)
  proc push[T](x: Stack; n: T) = discard
  proc popInt(x: var Stack, n: static[int]): auto =
    var rc: genTupleType(n, UInt256)
    return rc

  # function stubs from v2utils_numeric.nim
  func safeInt(x: Uint256): int = discard

  # function stubs from v2memory.nim
  proc len(mem: Memory): int = 0
  proc extend(mem: var Memory; startPos: Natural; size: Natural) = discard

  # function stubs from v2computation.nim (to satisfy compiler logic)
  proc gasCosts(c: Computation): array[Op,int] = blindGasCosts

  # function stubs from gas_meter.nim
  proc consumeGas(gasMeter: var GasMeter; amount: int; reason: string) = discard

  # dummy stubs from constants
  const EMPTY_SHA3 = 0xdeadbeef.u256

  # function stubs from nimcrypto/hash.nim and nimcrypto/keccak.nim
  const keccak256 = 0xfeedbeef
  proc digest(dummy: int64, data: openarray[byte]): UInt256 = EMPTY_SHA3

  # stubs from v2gas_costs.nim
  proc m_handler(x: int; curMemSize, memOffset, memLen: int64): int = 0

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  sha3Op: Vm2OpFn = proc (k: Vm2Ctx) =
    ## 0x20, Compute Keccak-256 hash.
    let (startPos, length) = k.cpt.stack.popInt(2)

    let (pos, len) = (startPos.safeInt, length.safeInt)
    if pos < 0 or len < 0 or pos > 2147483648'i64:
      raise newException(OutOfBoundsRead, "Out of bounds memory access")

    k.cpt.gasMeter.consumeGas(
      k.cpt.gasCosts[Op.Sha3].m_handler(k.cpt.memory.len, pos, len),
      reason = "SHA3: word gas cost")

    k.cpt.memory.extend(pos, len)

    let endRange = min(pos + len, k.cpt.memory.len) - 1
    if endRange == -1 or pos >= k.cpt.memory.len:
      k.cpt.stack.push(EMPTY_SHA3)
    else:
      k.cpt.stack.push:
        keccak256.digest k.cpt.memory.bytes.toOpenArray(pos, endRange)

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecHash*: seq[Vm2OpExec] = @[

    (opCode: Op.Sha3,     ## 0x20, Keccak-256
     forks: Vm2OpAllForks,
     info: "Compute Keccak-256 hash",
     exec: (prep: vm2OpIgnore,
            run:  sha3Op,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
