import
  eth/common, stint, evmc/evmc,
  interpreter/vm_forks

const
  evmc_native* {.booldefine.} = false

func toEvmc*(a: EthAddress): evmc_address {.inline.} =
  cast[evmc_address](a)

func toEvmc*(h: Hash256): evmc_bytes32 {.inline.} =
  cast[evmc_bytes32](h)

func toEvmc*(n: Uint256): evmc_uint256be {.inline.} =
  when evmc_native:
    cast[evmc_uint256be](n)
  else:
    cast[evmc_uint256be](n.toByteArrayBE)

func fromEvmc*(T: type, n: evmc_bytes32): T {.inline.} =
  when T is Hash256:
    cast[Hash256](n)
  elif T is Uint256:
    when evmc_native:
      cast[Uint256](n)
    else:
      Uint256.fromBytesBE(n.bytes)
  else:
    {.error: "cannot convert unsupported evmc type".}

func fromEvmc*(a: evmc_address): EthAddress {.inline.} =
  cast[EthAddress](a)

func fromEvmc*(x: evmc_revision): Fork =
  const nimbus_rev: array[evmc_revision, Fork] = [
    FkFrontier, FkHomestead, FkTangerine,
    FkSpurious, FkByzantium, FkConstantinople,
    FkPetersburg, FkIstanbul,
    FkIstanbul] # TODO: this one should be FkBerlin
  result = nimbus_rev[x]

func toEvmc*(x: Fork): evmc_revision =
  const evmc_rev: array[Fork, evmc_revision] = [
    EVMC_FRONTIER, EVMC_FRONTIER,
    EVMC_HOMESTEAD, EVMC_HOMESTEAD,
    EVMC_TANGERINE_WHISTLE, EVMC_SPURIOUS_DRAGON,
    EVMC_BYZANTIUM, EVMC_CONSTANTINOPLE,
    EVMC_PETERSBURG, EVMC_ISTANBUL,
    EVMC_ISTANBUL]
  result = evmc_rev[x]

when isMainModule:
  import ..\constants
  var a: evmc_address
  a.bytes[19] = 3.byte
  var na = fromEvmc(a)
  assert(a == toEvmc(na))
  var b = stuint(10, 256)
  var eb = b.toEvmc
  assert(b == fromEvmc(Uint256, eb))
  var h = EMPTY_SHA3
  var eh = toEvmc(h)
  assert(h == fromEvmc(Hash256, eh))
