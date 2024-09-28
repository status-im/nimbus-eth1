# Nimbus
# Copyright (c) 2020-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common,
  stint,
  evmc/evmc,
  ../utils/utils

const
  evmc_native* {.booldefine.} = false

func toEvmc*(a: EthAddress): evmc_address {.inline.} =
  evmc_address(bytes: a.data)

func toEvmc*(h: Hash256): evmc_bytes32 {.inline.} =
  doAssert sizeof(h) == sizeof(evmc_bytes32)
  evmc_bytes32(bytes: h.data)

func toEvmc*(h: ContractSalt): evmc_bytes32 {.inline.} =
  doAssert sizeof(h) == sizeof(evmc_bytes32)
  cast[evmc_bytes32](h)

func toEvmc*(n: UInt256): evmc_uint256be {.inline.} =
  when evmc_native:
    cast[evmc_uint256be](n)
  else:
    cast[evmc_uint256be](n.toBytesBE)

func fromEvmc*(T: type, n: evmc_bytes32): T {.inline.} =
  when T is ContractSalt:
    doAssert sizeof(n) == sizeof(T)
    cast[T](n)
  elif T is Hash32:
    Hash32(n.bytes)
  elif T is UInt256:
    when evmc_native:
      cast[UInt256](n)
    else:
      UInt256.fromBytesBE(n.bytes)
  else:
    {.error: "cannot convert unsupported evmc type".}

func fromEvmc*(a: evmc_address): EthAddress {.inline.} =
  EthAddress(a.bytes)

when isMainModule:
  import ../constants
  var a: evmc_address
  a.bytes[19] = 3.byte
  var na = fromEvmc(a)
  assert(a == toEvmc(na))
  var b = stuint(10, 256)
  var eb = b.toEvmc
  assert(b == fromEvmc(UInt256, eb))
  var h = EMPTY_SHA3
  var eh = toEvmc(h)
  assert(h == fromEvmc(Hash256, eh))
  var s = cast[ContractSalt](EMPTY_ROOT_HASH)
  var es = toEvmc(s)
  assert(s == fromEvmc(ContractSalt, es))
