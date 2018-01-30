
import
  bigints, math, strutils, tables, utils/padding

type
  TypeHint* {.pure.} = enum UInt256, Bytes, Any

  Int256* = BigInt #distinct int # TODO

proc int256*(i: int): Int256 =
  i.initBigInt

template i256*(i: int): Int256 =
  i.int256

# TODO
# We'll have a fast fixed i256, for now this works

proc `==`*(a: Int256, b: int): bool =
  a == b.i256

proc `!=`*(a: Int256, b: int): bool =
  a != b.i256

proc `^`*(base: int; exp: int): Int256 =
  let base = base.initBigInt
  var ex = exp
  result = 1.initBigInt
  while ex > 0:
    result *= base
    dec(ex)

proc `^`*(left: Int256, right: int): Int256 =
  var value = right.initBigInt
  result = 1.initBigInt
  var m = right.i256
  while value > 0.i256:
    result = result * m
    value -= 1.i256

proc `>`*(a: Int256, b: int): bool =
  a > b.i256

proc `<`*(a: Int256, b: int): bool =
  a < b.i256

proc `mod`*(a: Int256, b: int): Int256 =
  a mod b.i256

proc `div`*(a: Int256, b: int): Int256 =
  a div b.i256

proc log256*(a: Int256): Int256 =
  # TODO
  2.i256

proc setXLen[T](s: var seq[T]; newlen: Natural) =
  if s.isNil:
    s = newSeq[T](newlen)
  else:
    s.setLen(newlen)

template mapOp(op: untyped): untyped =
  proc `op`*(left: Int256, right: Int256): Int256 =
    result = left.initBigInt
    var maxRight = right.initBigInt
    var l = max(left.limbs.len, right.limbs.len)
    result.limbs.setXLen(l)
    maxRight.limbs.setXLen(l)
    for z in 0 ..< l:
      result.limbs[z] = `op`(result.limbs[z], maxRight.limbs[z])

mapOp(`and`)
mapOp(`or`)
mapOp(`xor`)

proc `abs`*(a: Int256): Int256 =
  if a >= 0.i256: a else: -a

proc `getInt`*(a: Int256): int =
  a.limbs[0].int

let
  UINT_256_MAX*: Int256 =         2 ^ 256 - 1
  UINT_256_CEILING*: Int256 =     2 ^ 256
  UINT_255_MAX*: Int256 =         2 ^ (256 - 1) - 1
  UINT_255_CEILING*: Int256 =     2 ^ (256 - 1)

  NULLBYTE* =                     cstring"\x00"
  EMPTYWORD* =                    repeat(NULLBYTE, 32)
  UINT160CEILING*: Int256 =       2 ^ 160
  CREATE_CONTRACT_ADDRESS* =      cstring""
  ZERO_ADDRESS* =                 repeat(cstring"\x00", 20)
  ZERO_HASH32* =                  repeat(cstring"\x00", 20)
  STACKDEPTHLIMIT* =              1024
  
  GAS_NULL* =                     0.i256
  GAS_ZERO* =                     0.i256
  GAS_BASE* =                     2.i256
  GAS_VERY_LOW* =                 3.i256
  GAS_LOW* =                      5.i256
  GAS_MID* =                      8.i256
  GAS_HIGH* =                     10.i256
  GAS_EXT_CODE* =                 20.i256
  GAS_BALANCE* =                  20.i256
  GAS_SLOAD* =                    50.i256
  GAS_JUMP_DEST* =                1.i256
  GAS_SSET* =                     20_000.i256
  GAS_SRESET* =                   5000.i256
  GAS_EXT_CODE_COST* =            700.i256
  GAS_COINBASE* =                 20.i256
  GAS_SLOAD_COST* =               20.i256
  GAS_SELF_DESTRUCT_COST* =       5_000.i256
  GAS_IN_HANDLER* =               0.i256 # to be calculated in handler
  REFUNDS_CLEAR* =                15_000.i256
  
  GAS_SELF_DESTRUCT* =            0.i256
  GAS_SELF_DESTRUCT_NEW_ACCOUNT* = 25_000.i256
  GAS_CREATE* =                   32_000.i256
  GAS_CALL* =                     40.i256
  GASCALLVALUE =                  9_000.i256
  GAS_CALL_STIPEND* =             2_300.i256
  GAS_NEW_ACCOUNT* =              25_000.i256
  
  GAS_COST_BALANCE* =             400.i256

  GAS_EXP* =                      10.i256
  GAS_EXP_BYTE* =                 10.i256
  GAS_MEMORY* =                   3.i256
  GAS_TX_CREATE* =                32_000.i256
  GAS_TX_DATA_ZERO* =             4.i256
  GAS_TX_DATA_NON_ZERO* =         68.i256
  GAS_TX* =                       21_000.i256
  GAS_LOG* =                      375.i256
  GAS_LOG_DATA* =                 8.i256
  GAS_LOG_TOPIC* =                375.i256
  GAS_SHA3* =                     30.i256
  GAS_SHA3_WORD* =                6.i256
  GAS_COPY* =                     3.i256
  GAS_BLOCK_HASH* =               20.i256
  GAS_CODE_DEPOSIT* =             200.i256
  GAS_MEMORY_QUADRATIC_DENOMINATOR* = 512.i256
  GAS_SHA256* =                   60.i256
  GAS_SHA256WORD* =               12.i256
  GAS_RIP_EMD160* =               600.i256
  GAS_RIP_EMD160WORD* =           120.i256
  GAS_IDENTITY* =                 15.i256
  GAS_IDENTITY_WORD* = 3
  GAS_ECRECOVER* =                3_000.i256
  GAS_ECADD* =                    500.i256
  GAS_ECMUL* =                    40_000.i256
  GAS_ECPAIRING_BASE* =           100_000.i256
  GAS_ECPAIRING_PER_POINT* =      80_000.i256
  GAS_LIMIT_EMA_DENOMINATOR* =    1_024.i256
  GAS_LIMIT_ADJUSTMENT_FACTOR* =  1_024.i256
  GAS_LIMIT_MAXIMUM*: Int256 =    2 ^ 63 - 1
  GAS_LIMIT_USAGE_ADJUSTMENT_NUMERATOR* = 3.i256
  GAS_LIMIT_USAGE_ADJUSTMENT_DENOMINATOR* = 2.i256
  
  DIFFICULTY_ADJUSTMENT_DENOMINATOR* = 2_048.i256
  DIFFICULTY_MINIMUM* =           131_072.i256
  
  BOMB_EXPONENTIAL_PERIOD* =      100_000.i256
  BOMB_EXPONENTIAL_FREE_PERIODS* = 2.i256
  
  BLOCK_REWARD* =                 5.i256 * 2.i256 # denoms.ether
  
  UNCLE_DEPTH_PENALTY_FACTOR* =   8.i256
  
  MAX_UNCLE_DEPTH* =              6.i256
  MAX_UNCLES* =                   2.i256
  
  SECPK1_P*: Int256 =             2 ^ 256 - 2 ^ 32 - 977
  SECPK1_N*: Int256 =             "115792089237316195423570985008687907852837564279074904382605163141518161494337".initBigInt
  SECPK1_A* =                     0.i256
  SECPK1_B* =                     7.i256
  SECPK1_Gx* =                    0.i256
  SECPK1_Gy* =                    0.i256
  SECPK1_G* =                     (SECPK1Gx, SECPK1Gy)
  
  EMPTY_UNCLE_HASH* =             cstring"\x1d\xccM\xe8\xde\xc7]z\xab\x85\xb5g\xb6\xcc\xd4\x1a\xd3\x12E\x1b\x94\x8at\x13\xf0\xa1B\xfd@\xd4\x93G"
  
  GENESIS_BLOCK_NUMBER* =         0.i256
  GENESIS_DIFFICULTY* =           131_072.i256
  GENESIS_GAS_LIMIT* =            3_141_592.i256
  GENESIS_PARENT_HASH* =          ZERO_HASH32
  GENESIS_COINBASE* =             ZERO_ADDRESS
  GENESIS_NONCE* =                cstring"\x00\x00\x00\x00\x00\x00\x00B"
  GENESIS_MIX_HASH* =             ZERO_HASH32
  GENESIS_EXTRA_DATA =            cstring""
  
  EMPTYSHA3 =                     cstring"\xc5\xd2F\x01\x86\xf7#<\x92~}\xb2\xdc\xc7\x03\xc0\xe5\x00\xb6S\xca\x82';{\xfa\xd8\x04]\x85\xa4p"  
  BLANK_ROOT_HASH* =              cstring"V\xe8\x1f\x17\x1b\xccU\xa6\xff\x83E\xe6\x92\xc0\xf8n[H\xe0\x1b\x99l\xad\xc0\x01b/\xb5\xe3c\xb4!"
  
  GAS_MOD_EXP_QUADRATIC_DENOMINATOR* = 20.i256

  MAX_PREV_HEADER_DEPTH* = 256.i256

