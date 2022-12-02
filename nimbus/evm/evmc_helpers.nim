import
  eth/common,
  stint,
  evmc/evmc,
  ../utils/utils

const
  evmc_native* {.booldefine.} = false

func toEvmc*(a: EthAddress): evmc_address {.inline.} =
  cast[evmc_address](a)

func toEvmc*(h: Hash256 | ContractSalt): evmc_bytes32 {.inline.} =
  doAssert sizeof(h) == sizeof(evmc_bytes32)
  cast[evmc_bytes32](h)

func toEvmc*(n: UInt256): evmc_uint256be {.inline.} =
  when evmc_native:
    cast[evmc_uint256be](n)
  else:
    cast[evmc_uint256be](n.toByteArrayBE)

func fromEvmc*(T: type, n: evmc_bytes32): T {.inline.} =
  when T is Hash256 | ContractSalt:
    doAssert sizeof(n) == sizeof(T)
    cast[T](n)
  elif T is UInt256:
    when evmc_native:
      cast[UInt256](n)
    else:
      UInt256.fromBytesBE(n.bytes)
  else:
    {.error: "cannot convert unsupported evmc type".}

func fromEvmc*(a: evmc_address): EthAddress {.inline.} =
  cast[EthAddress](a)

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
