
import
  math, strutils, tables #, eth_utils

type
  TypeHint* {.pure.} = enum UInt256, Bytes, Any

  Int256* = distinct int # TODO

# TODO
# We'll have a fast fixed Int256, for now this

proc `==`*(a: Int256, b: Int256): bool =
  a.int == b.int

proc `==`*(a: Int256, b: int): bool =
  a.int == b

proc `!=`*(a: Int256, b: Int256): bool =
  a.int != b.int

proc `!=`*(a: Int256, b: int): bool =
  a.int != b

proc `^`*(a: Int256, b: Int256): Int256 =
  (a.int ^ b.int).Int256

proc `^`*(a: Int256, b: int): Int256 =
  (a.int ^ b).Int256

proc `>`*(a: Int256, b: Int256): bool =
  a.int > b.int

proc `>`*(a: Int256, b: int): bool =
  a.int > b

proc `>=`*(a: Int256, b: Int256): bool =
  a.int >= b.int

proc `<`*(a: Int256, b: Int256): bool =
  a.int < b.int

proc `<`*(a: Int256, b: int): bool =
  a.int < b

proc `<=`*(a: Int256, b: Int256): bool =
  a.int <= b.int

proc `$`*(a: Int256): string =
  $(a.int)

proc `-`*(a: Int256, b: Int256): Int256 =
  (a.int - b.int).Int256

proc `+`*(a: Int256, b: Int256): Int256 =
  (a.int + b.int).Int256

proc `-=`*(a: var Int256, b: Int256) =
  a = (a - b).Int256

proc `+=`*(a: var Int256, b: Int256) =
  a = (a + b).Int256

proc `*`*(a: Int256, b: Int256): Int256 =
  (a.int * b.int).Int256

proc `mod`*(a: Int256, b: Int256): Int256 =
  (a.int mod b.int).Int256

proc `mod`*(a: Int256, b: int): Int256 =
  (a.int mod b).Int256

proc `div`*(a: Int256, b: Int256): Int256 =
  (a.int div b.int).Int256

proc `div`*(a: Int256, b: int): Int256 =
  (a.int div b).Int256

proc `abs`*(a: Int256): Int256 =
  a.int.abs.Int256

proc `and`*(a: Int256, b: Int256): Int256 =
  (a.int and b.int).Int256

proc `or`*(a: Int256, b: Int256): Int256 =
  (a.int or b.int).Int256

proc `xor`*(a: Int256, b: Int256): Int256 =
  (a.int xor b.int).Int256

proc max*(a: Int256, b: Int256): Int256 =
  max(a.int, b.int).Int256

proc min*(a: Int256, b: Int256): Int256 =
  min(a.int, b.int).Int256

proc `-`*(a: Int256): Int256 =
  (-(a.int)).Int256

proc `shl`*(a: Int256, b: Int256): Int256 =
  (a.int shl b.int).Int256

proc `shr`*(a: Int256, b: Int256): Int256 =
  (a.int shr b.int).Int256

proc repeat(b: cstring, count: int): cstring =
  # TODO: faster
  var s = $b
  result = cstring(repeat(s, count))

const
  X = 62 # 256
  UINT_256_MAX* = (2 ^ X - 1).Int256
  UINT_256_CEILING* = (2 ^ X).Int256
  UINT_255_MAX* = (2 ^ (X - 1) - 1).Int256
  UINT_255_CEILING* = (2 ^ (X - 1)).Int256
  NULLBYTE = cstring"\x00"
  EMPTYWORD = repeat(NULLBYTE, 32)
  # UINT160CEILING = 2 ^ 160
  CREATE_CONTRACT_ADDRESS* = cstring""
  ZERO_ADDRESS* = repeat(cstring"\x00", 20)
  ZERO_HASH32* = repeat(cstring"\x00", 20)
  STACKDEPTHLIMIT* = 1024
  GAS_NULL* = 0.Int256
  GAS_ZERO* = 0.Int256
  GAS_BASE* = 2.Int256
  GAS_VERY_LOW* = 3.Int256
  GAS_LOW* = 5.Int256
  GAS_MID* = 8.Int256
  GAS_HIGH* = 10.Int256
  GAS_EXT_CODE* = 20.Int256
  GAS_BALANCE* = 20.Int256
  GAS_SLOAD* = 50.Int256
  GAS_JUMP_DEST* = 1.Int256
  GAS_SSET* = 20000.Int256
  GAS_SRESET* = 5000.Int256
  REFUNDSCLEAR = 15000
  GASSELFDESTRUCT = 0
  GASSELFDESTRUCTNEWACCOUNT = 25000
  GASCREATE = 32000
  GASCALL = 40
  GASCALLVALUE = 9000
  GASCALLSTIPEND = 2300
  GASNEWACCOUNT = 25000
  GASEXP = 10
  GASEXPBYTE = 10
  GAS_MEMORY* = 3.Int256
  GAS_TX_CREATE* = 32000.Int256
  GAS_TX_DATA_ZERO* = 4.Int256
  GAS_TX_DATA_NON_ZERO* = 68.Int256
  GAS_TX* = 21000.Int256
  GAS_LOG* = 375.Int256
  GASLOGDATA = 8
  GASLOGTOPIC = 375
  GASSHA3 = 30
  GASSHA3WORD = 6
  GASCOPY = 3
  GASBLOCKHASH = 20
  GASCODEDEPOSIT = 200
  GAS_MEMORY_QUADRATIC_DENOMINATOR* = 512.Int256
  GAS_SHA256 = 60.Int256
  GASSHA256WORD = 12
  GASRIPEMD160 = 600
  GASRIPEMD160WORD = 120
  GASIDENTITY = 15
  GASIDENTITYWORD = 3
  GASECRECOVER = 3000
  GASECADD = 500
  GASECMUL = 40000
  GASECPAIRINGBASE = 100000
  GASECPAIRINGPERPOINT = 80000
  GASLIMITEMADENOMINATOR = 1024
  GASLIMITADJUSTMENTFACTOR = 1024
  GASLIMITMINIMUM = 5000
  # GASLIMITMAXIMUM = 2 ^ 63 - 1
  GAS_LIMIT_USAGE_ADJUSTMENT_NUMERATOR* = 3.Int256
  GAS_LIMIT_USAGE_ADJUSTMENT_DENOMINATOR* = 2.Int256
  DIFFICULTY_ADJUSTMENT_DENOMINATOR* = 2_048.Int256
  DIFFICULTY_MINIMUM* = 131_072.Int256
  BOMB_EXPONENTIAL_PERIOD* = 100_000.Int256
  BOMB_EXPONENTIAL_FREE_PERIODS* = 2.Int256
  BLOCK_REWARD* = 5.Int256 * 2.Int256 # denoms.ether
  UNCLE_DEPTH_PENALTY_FACTOR* = 8.Int256
  MAXUNCLEDEPTH = 6
  MAXUNCLES = 2
  # SECPK1P = 2 ^ 256 - 2 ^ 32 - 977
  SECPK1N = 0
  SECPK1A = 0
  SECPK1B = 7
  SECPK1Gx = 0
  SECPK1Gy = 0
  SECPK1G = (SECPK1Gx, SECPK1Gy)
  EMPTYUNCLEHASH = cstring"\x1d\xccM\xe8\xde\xc7]z\xab\x85\xb5g\xb6\xcc\xd4\x1a\xd3\x12E\x1b\x94\x8at\x13\xf0\xa1B\xfd@\xd4\x93G"
  GENESIS_BLOCK_NUMBER* = 0.Int256
  GENESIS_DIFFICULTY* = 131_072.Int256
  GENESIS_GAS_LIMIT* = 3_141_592.Int256
  GENESIS_PARENT_HASH* = ZERO_HASH32
  GENESIS_COINBASE* = ZERO_ADDRESS
  GENESIS_NONCE* = cstring"\x00\x00\x00\x00\x00\x00\x00B"
  GENESIS_MIX_HASH* = ZERO_HASH32
  GENESIS_EXTRA_DATA = cstring""
  EMPTYSHA3 = cstring"\xc5\xd2F\x01\x86\xf7#<\x92~}\xb2\xdc\xc7\x03\xc0\xe5\x00\xb6S\xca\x82';{\xfa\xd8\x04]\x85\xa4p"
  BLANK_ROOT_HASH* = cstring"V\xe8\x1f\x17\x1b\xccU\xa6\xff\x83E\xe6\x92\xc0\xf8n[H\xe0\x1b\x99l\xad\xc0\x01b/\xb5\xe3c\xb4!"
  GAS_MOD_EXP_QUADRATIC_DENOMINATOR* = 20
  MAX_PREV_HEADER_DEPTH* = 256
