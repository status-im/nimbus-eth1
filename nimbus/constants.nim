{.used.}

import
  eth/common, nimcrypto/hash

proc default(t: typedesc): t = discard

# constants
const
  UINT_256_MAX*: UInt256 =                  high(UInt256)
  INT_256_MAX_AS_UINT256* =                 high(Uint256) shr 1
  UINT160CEILING*: UInt256 =                2.u256.pow(160)

  # Transactions to ZERO_ADDRESS are legitimate transfers to that account, not
  # contract creations.  They are used to "burn" Eth.  People also send Eth to
  # address zero by accident, unrecoverably, due to poor user interface issues.
  ZERO_ADDRESS* =                           default(EthAddress)

  # ZERO_HASH256 is the parent hash of genesis blocks.
  ZERO_HASH256* =                           Hash256()

  GAS_LIMIT_ADJUSTMENT_FACTOR* =            1_024

  BLOCK_REWARD* =                           5.u256 * 2.u256 # denoms.ether

  UNCLE_DEPTH_PENALTY_FACTOR* =             8.u256

  MAX_UNCLE_DEPTH* =                        6.u256
  MAX_UNCLES* =                             2

  EMPTY_UNCLE_HASH* =                       "1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347".toDigest

  GENESIS_BLOCK_NUMBER* =                   0.toBlockNumber
  GENESIS_DIFFICULTY* =                     131_072.u256
  GENESIS_GAS_LIMIT* =                      3_141_592
  GENESIS_PARENT_HASH* =                    ZERO_HASH256
  GENESIS_COINBASE* =                       ZERO_ADDRESS
  GENESIS_NONCE* =                          "\x00\x00\x00\x00\x00\x00\x00B"
  GENESIS_MIX_HASH* =                       ZERO_HASH256
  GENESIS_EXTRA_DATA* =                     ""
  GAS_LIMIT_MINIMUM* =                      5000
  GAS_LIMIT_MAXIMUM* =                      high(GasInt)
  DEFAULT_GAS_LIMIT* =                      8_000_000

  BLANK_ROOT_HASH* =                        "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421".toDigest
  EMPTY_SHA3* =                             "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470".toDigest

  GAS_MOD_EXP_QUADRATIC_DENOMINATOR* =      20.u256

  MAX_PREV_HEADER_DEPTH* =                  256.toBlockNumber
  MaxCallDepth* =                           1024

  SECPK1_N* =                               Uint256.fromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")

  ## Fork specific constants

  # See EIP-170 (https://eips.ethereum.org/EIPS/eip-170).  Maximum code size
  # that can be stored for a new contract.  Init code when creating a new
  # contract is not subject to this limit.
  EIP170_MAX_CODE_SIZE* =                   0x6000

  # EIP
  MaxPrecompilesAddr* =                     0xFFFF

  EXTRA_SEAL* = ##\
    ## Fixed number of suffix bytes reserved for signer seal of the `extraData`
    ## header field. The 65 bytes constant value is for signatures based on the
    ## standard secp256k1 curve.
    65

  DEFAULT_RPC_GAS_CAP* =                    50_000_000.GasInt

# End
