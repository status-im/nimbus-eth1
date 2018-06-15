
import
  math, strutils, utils/padding, eth_common

proc default(t: typedesc): t = discard

# constants
let # TODO - replace by const - https://github.com/status-im/nim-stint/issues/52
  UINT_256_MAX*: UInt256 =        high(UInt256)
  INT_256_MAX_AS_UINT256* =       cast[Uint256](high(Int256))
  NULLBYTE* =                     "\x00"
  EMPTYWORD* =                    repeat(NULLBYTE, 32)
  UINT160CEILING*: UInt256 =      2.u256.pow(160)
  ZERO_ADDRESS* =                 default(EthAddress)
  CREATE_CONTRACT_ADDRESS* =      ZERO_ADDRESS
  ZERO_HASH32* =                  Hash256()
  STACK_DEPTH_LIMIT* =            1024

  GAS_LIMIT_EMA_DENOMINATOR* =    1_024
  GAS_LIMIT_ADJUSTMENT_FACTOR* =  1_024
  GAS_LIMIT_USAGE_ADJUSTMENT_NUMERATOR* = 3
  GAS_LIMIT_USAGE_ADJUSTMENT_DENOMINATOR* = 2

  DIFFICULTY_ADJUSTMENT_DENOMINATOR* = 2_048.u256
  DIFFICULTY_MINIMUM* =           131_072.u256
  BYZANTIUM_DIFFICULTY_ADJUSTMENT_CUTOFF* = 9

  BOMB_EXPONENTIAL_PERIOD* =      100_000.u256
  BOMB_EXPONENTIAL_FREE_PERIODS* = 2.u256

  BLOCK_REWARD* =                 5.u256 * 2.u256 # denoms.ether

  UNCLE_DEPTH_PENALTY_FACTOR* =   8.u256

  MAX_UNCLE_DEPTH* =              6.u256
  MAX_UNCLES* =                   2.u256

  EMPTY_UNCLE_HASH* =             "1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347".toDigest

  GENESIS_BLOCK_NUMBER* =         0.u256
  GENESIS_DIFFICULTY* =           131_072.u256
  GENESIS_GAS_LIMIT* =            3_141_592
  GENESIS_PARENT_HASH* =          ZERO_HASH32
  GENESIS_COINBASE* =             ZERO_ADDRESS
  GENESIS_NONCE* =                "\x00\x00\x00\x00\x00\x00\x00B"
  GENESIS_MIX_HASH* =             ZERO_HASH32
  GENESIS_EXTRA_DATA* =           ""
  GAS_LIMIT_MINIMUM* =            5000

  BLANK_ROOT_HASH* =              "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421".toDigest
  EMPTY_SHA3* =                   "883f7328a6c30727a655daff17eba3a86049871bc7839a5b71e2bc26a99c4d4c".toDigest

  GAS_MOD_EXP_QUADRATIC_DENOMINATOR* = 20.u256

  MAX_PREV_HEADER_DEPTH* =        256.toBlockNumber

