
import
  math, strutils, utils/padding, eth_common

proc default(t: typedesc): t = discard

# constants

let
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

  EMPTYSHA3 =                     "\xc5\xd2F\x01\x86\xf7#<\x92~}\xb2\xdc\xc7\x03\xc0\xe5\x00\xb6S\xca\x82';{\xfa\xd8\x04]\x85\xa4p"
  BLANK_ROOT_HASH* =              "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421".toDigest()

  GAS_MOD_EXP_QUADRATIC_DENOMINATOR* = 20.u256

  MAX_PREV_HEADER_DEPTH* =        256.toBlockNumber

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

