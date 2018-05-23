
import
  stint, math, strutils, tables, utils/padding, rlp, times

# rlpFields UInt256, table

type
  TypeHint* {.pure.} = enum UInt256, Bytes, Any # TODO Bytes is in conflict with nim-rlp Bytes = seq[byte]
  EthTime* = Time


  #Bytes* = seq[byte]

  # Int256* = BigInt #distinct int # TODO

proc int256*(i: int): Int256 =
  i.i256

# template i256*(i: int): Int256 =
#   i.initBigInt

template i256*(i: Int256): Int256 =
  i

template u256*(i: int): UInt256 =
  i.uint.u256

template u256*(i: UInt256): UInt256 =
  i

template getInt*(i: int): int =
  i

# TODO
# We'll have a fast fixed i256, for now this works

proc `==`*(a: Int256, b: int): bool =
  a == b.i256

proc `!=`*(a: Int256, b: int): bool =
  a != b.i256

proc `==`*(a: UInt256, b: int): bool =
  a == b.u256

proc `!=`*(a: UInt256, b: int): bool =
  a != b.u256

proc `^`*(base: int; exp: int): UInt256 =
  let base = base.u256
  var ex = exp
  result = 1.u256
  while ex > 0:
    result = result * base
    dec(ex)

proc `^`*(left: Int256, right: int): Int256 =
  var value = right.i256
  result = 1.i256
  var m = right.i256
  while value > 0.i256:
    result = result * m
    value -= 1.i256

proc `^`*(left: UInt256, right: UInt256): UInt256 =
  var value = right
  result = 1.u256
  var m = right.u256
  while value > 0.u256:
    result = result * m
    value -= 1.u256

proc `^`*(left: UInt256, right: int): UInt256 =
  left ^ right.u256

proc `>`*(a: Int256, b: int): bool =
  a > b.i256

proc `<`*(a: Int256, b: int): bool =
  a < b.i256

proc `>`*(a: UInt256, b: int): bool =
  a > b.u256

proc `<`*(a: UInt256, b: int): bool =
  a < b.u256

proc `mod`*(a: Int256, b: int): Int256 =
  a mod b.i256

proc `div`*(a: Int256, b: int): Int256 =
  a div b.i256

proc `mod`*(a: UInt256, b: int): UInt256 =
  a mod b.u256

proc `div`*(a: UInt256, b: int): UInt256 =
  a div b.u256

proc setXLen[T](s: var seq[T]; newlen: Natural) =
  if s.isNil:
    s = newSeq[T](newlen)
  else:
    s.setLen(newlen)

template mapOp(op: untyped): untyped =
  proc `op`*(left: Int256, right: int): Int256 =
    result = left.i256
    result = `op`(result, right.i256)

  proc `op`*(left: UInt256, right: int): UInt256 =
    result = left.u256
    result = `op`(result, right.u256)

mapOp(`and`)
mapOp(`or`)
mapOp(`xor`)

# constants

let
  UINT_256_MAX*: UInt256 =        high(UInt256)
  INT_256_MAX_AS_UINT256* =       cast[Uint256](high(Int256))
  NULLBYTE* =                     "\x00"
  EMPTYWORD* =                    repeat(NULLBYTE, 32)
  UINT160CEILING*: UInt256 =      2 ^ 160
  CREATE_CONTRACT_ADDRESS* =      ""
  ZERO_ADDRESS* =                 repeat("\x00", 20)
  ZERO_HASH32* =                  repeat("\x00", 20)
  STACK_DEPTH_LIMIT* =            1024

  # GAS_NULL* =                     0.u256
  # GAS_ZERO* =                     0.u256
  # GAS_BASE* =                     2.u256
  # GAS_VERY_LOW* =                 3.u256
  # GAS_LOW* =                      5.u256
  # GAS_MID* =                      8.u256
  # GAS_HIGH* =                     10.u256
  # GAS_EXT_CODE* =                 20.u256 # TODO: this is pre-eip150, see also GAS_EXT_CODE_COST
  # GAS_BALANCE* =                  20.u256 # TODO: this is pre-eip150, see also GAS_COST_BALANCE
  # GAS_SLOAD* =                    200.u256 # TODO: pre eip150
  # GAS_JUMP_DEST* =                1.u256
  # GAS_SSET* =                     20_000.u256
  # GAS_SRESET* =                   5_000.u256
  # GAS_EXT_CODE_COST* =            700.u256
  # GAS_COINBASE* =                 20.u256
  # GAS_SLOAD_COST* =               20.u256
  # GAS_SELF_DESTRUCT_COST* =       0.u256
  # GAS_IN_HANDLER* =               0.u256 # to be calculated in handler
  REFUND_SCLEAR* =                15_000.u256

  # GAS_SELF_DESTRUCT* =            0.u256
  # GAS_SELF_DESTRUCT_NEW_ACCOUNT* = 25_000.u256
  GAS_CREATE* =                   32_000.u256
  # GAS_CALL* =                     40.u256
  GAS_CALL_VALUE* =               9_000.u256
  GAS_CALL_STIPEND* =             2_300.u256
  GAS_NEW_ACCOUNT* =              25_000.u256

  # GAS_COST_BALANCE* =             400.u256 # TODO: this is post-eip150, see also GAS_BALANCE

  # GAS_EXP* =                      10.u256
  # GAS_EXP_BYTE* =                 10.u256
  GAS_MEMORY* =                   3.u256
  GAS_TX_CREATE* =                32_000.u256
  GAS_TX_DATA_ZERO* =             4.u256
  GAS_TX_DATA_NON_ZERO* =         68.u256
  GAS_TX* =                       21_000.u256
  GAS_LOG* =                      375.u256
  GAS_LOG_DATA* =                 8.u256
  GAS_LOG_TOPIC* =                375.u256
  # GAS_SHA3* =                     30.u256
  GAS_SHA3_WORD* =                6.u256
  GAS_COPY* =                     3.u256
  GAS_BLOCK_HASH* =               20.u256
  GAS_CODE_DEPOSIT* =             200.u256
  GAS_MEMORY_QUADRATIC_DENOMINATOR* = 512.u256
  GAS_SHA256* =                   60.u256
  GAS_SHA256WORD* =               12.u256
  GAS_RIP_EMD160* =               600.u256
  GAS_RIP_EMD160WORD* =           120.u256
  GAS_IDENTITY* =                 15.u256
  GAS_IDENTITY_WORD* = 3
  GAS_ECRECOVER* =                3_000.u256
  GAS_ECADD* =                    500.u256
  GAS_ECMUL* =                    40_000.u256
  GAS_ECPAIRING_BASE* =           100_000.u256
  GAS_ECPAIRING_PER_POINT* =      80_000.u256
  GAS_LIMIT_EMA_DENOMINATOR* =    1_024.u256
  GAS_LIMIT_ADJUSTMENT_FACTOR* =  1_024.u256
  GAS_LIMIT_MAXIMUM*: UInt256 =   2 ^ 63 - 1.u256
  GAS_LIMIT_USAGE_ADJUSTMENT_NUMERATOR* = 3.u256
  GAS_LIMIT_USAGE_ADJUSTMENT_DENOMINATOR* = 2.u256

  DIFFICULTY_ADJUSTMENT_DENOMINATOR* = 2_048.u256
  DIFFICULTY_MINIMUM* =           131_072.u256
  BYZANTIUM_DIFFICULTY_ADJUSTMENT_CUTOFF* = 9

  BOMB_EXPONENTIAL_PERIOD* =      100_000.u256
  BOMB_EXPONENTIAL_FREE_PERIODS* = 2.u256

  BLOCK_REWARD* =                 5.u256 * 2.u256 # denoms.ether

  UNCLE_DEPTH_PENALTY_FACTOR* =   8.u256

  MAX_UNCLE_DEPTH* =              6.u256
  MAX_UNCLES* =                   2.u256

  SECPK1_P*: UInt256 =            2 ^ 256 - 2 ^ 32 - 977.u256
  SECPK1_N*: UInt256 =            "115792089237316195423570985008687907852837564279074904382605163141518161494337".u256
  SECPK1_A* =                     0.u256
  SECPK1_B* =                     7.u256
  SECPK1_Gx* =                    0.u256
  SECPK1_Gy* =                    0.u256
  SECPK1_G* =                     (SECPK1Gx, SECPK1Gy)

  EMPTY_UNCLE_HASH* =             "\x1d\xccM\xe8\xde\xc7]z\xab\x85\xb5g\xb6\xcc\xd4\x1a\xd3\x12E\x1b\x94\x8at\x13\xf0\xa1B\xfd@\xd4\x93G"

  GENESIS_BLOCK_NUMBER* =         0.u256
  GENESIS_DIFFICULTY* =           131_072.u256
  GENESIS_GAS_LIMIT* =            3_141_592.u256
  GENESIS_PARENT_HASH* =          ZERO_HASH32
  GENESIS_COINBASE* =             ZERO_ADDRESS
  GENESIS_NONCE* =                "\x00\x00\x00\x00\x00\x00\x00B"
  GENESIS_MIX_HASH* =             ZERO_HASH32
  GENESIS_EXTRA_DATA* =           ""
  GAS_LIMIT_MINIMUM* =            5000.u256

  EMPTYSHA3 =                     "\xc5\xd2F\x01\x86\xf7#<\x92~}\xb2\xdc\xc7\x03\xc0\xe5\x00\xb6S\xca\x82';{\xfa\xd8\x04]\x85\xa4p"
  BLANK_ROOT_HASH* =              "V\xe8\x1f\x17\x1b\xccU\xa6\xff\x83E\xe6\x92\xc0\xf8n[H\xe0\x1b\x99l\xad\xc0\x01b/\xb5\xe3c\xb4!"

  GAS_MOD_EXP_QUADRATIC_DENOMINATOR* = 20.u256

  MAX_PREV_HEADER_DEPTH* = 256.u256

  FORK_ICEAGE_BLKNUM* =           200_000.u256
  FORK_HOMESTED_BLKNUM* =         1_150_000.u256
  FORK_DAO_BLKNUM* =              1_920_000.u256
  FORK_TANGERINE_WHISTLE_BLKNUM* = 2_463_000.u256
  FORK_SPURIOUS_DRAGON_BLKNUM* =  2_675_000.u256
  FORK_BYZANTIUM_BLKNUM* =        4_370_000.u256

# TODO: Move the below to a new utils unit?

type
  Fork = enum fkUnknown, fkFrontier, fkIceAge, fkHomested, fkDao, fkTangerineWhistle, fkSpuriousDragon, fkByzantium
  UInt256Pair = tuple[a: Uint256, b: Uint256]

proc `..`*(a, b: Uint256): UInt256Pair = (a, b)

proc contains*(ab: UInt256Pair, v: UInt256): bool =
  return v >= ab[0] and v <= ab[1]

proc toFork*(blockNumber: UInt256): Fork =
  # TODO - Refactoring: superseded by newNimbusVM for the time being #https://github.com/status-im/nimbus/pull/37
  # TODO - Refactoring: redundant with `chain.nim` getVM
  result = fkUnknown
  let one = u256(1)
  if blockNumber in u256(0)..FORK_ICEAGE_BLKNUM - one: result = fkFrontier
  elif blockNumber in FORK_ICEAGE_BLKNUM..FORK_HOMESTED_BLKNUM - one: result = fkIceAge
  elif blockNumber in FORK_HOMESTED_BLKNUM..FORK_DAO_BLKNUM - one: result = fkHomested
  elif blockNumber in FORK_DAO_BLKNUM..FORK_TANGERINE_WHISTLE_BLKNUM - one: result = fkDao
  elif blockNumber in FORK_TANGERINE_WHISTLE_BLKNUM..FORK_SPURIOUS_DRAGON_BLKNUM - one: result = fkTangerineWhistle
  elif blockNumber in FORK_SPURIOUS_DRAGON_BLKNUM..FORK_BYZANTIUM_BLKNUM - one: result = fkSpuriousDragon
  else:
    if blockNumber >= FORK_BYZANTIUM_BLKNUM: result = fkByzantium # Update for constantinople when announced

