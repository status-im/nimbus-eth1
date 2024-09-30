# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  stew/byteutils,
  eth/common/eth_types

# proc default(t: typedesc): t = discard -- notused

# constants
const
  UINT_256_MAX*: UInt256 =                  high(UInt256)
  INT_256_MAX_AS_UINT256* =                 high(UInt256) shr 1
  UINT160CEILING*: UInt256 =                2.u256.pow(160)

  # Transactions to ZERO_ADDRESS are legitimate transfers to that account, not
  # contract creations.  They are used to "burn" Eth.  People also send Eth to
  # address zero by accident, unrecoverably, due to poor user interface issues.
  ZERO_ADDRESS* =                           default(EthAddress)

  # ZERO_HASH256 is the parent hash of genesis blocks.
  ZERO_HASH256* =                           default(Hash256)

  GAS_LIMIT_ADJUSTMENT_FACTOR* =            1_024

  BLOCK_REWARD* =                           5.u256 * 2.u256 # denoms.ether

  UNCLE_DEPTH_PENALTY_FACTOR* =             8.u256

  MAX_UNCLE_DEPTH* =                        6
  MAX_UNCLES* =                             2

  GENESIS_BLOCK_NUMBER* =                   0.BlockNumber
  GENESIS_DIFFICULTY* =                     131_072.u256
  GENESIS_GAS_LIMIT* =                      3_141_592
  GENESIS_PARENT_HASH* =                    ZERO_HASH256
  GENESIS_COINBASE* =                       ZERO_ADDRESS
  GENESIS_NONCE* =                          "\x00\x00\x00\x00\x00\x00\x00B"
  GENESIS_MIX_HASH* =                       ZERO_HASH256
  GENESIS_EXTRA_DATA* =                     ""
  GAS_LIMIT_MINIMUM* =                      5000
  GAS_LIMIT_MAXIMUM* =                      int64.high.GasInt # Maximum the gas limit (2^63-1).
  DEFAULT_GAS_LIMIT* =                      8_000_000

  EMPTY_SHA3* =                             hash32"c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

  GAS_MOD_EXP_QUADRATIC_DENOMINATOR* =      20.u256

  MAX_PREV_HEADER_DEPTH* =                  256'u64
  MaxCallDepth* =                           1024

  SECPK1_N* =                               UInt256.fromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")

  ## Fork specific constants

  # See EIP-170 (https://eips.ethereum.org/EIPS/eip-170).  Maximum code size
  # that can be stored for a new contract.  Init code when creating a new
  # contract is not subject to this limit.
  EIP170_MAX_CODE_SIZE* =                   0x6000

  # See EIP-3860 (https://eips.ethereum.org/EIPS/eip-3860). Maximum initcode
  # size when creating a new contract.
  EIP3860_MAX_INITCODE_SIZE* =              2 * EIP170_MAX_CODE_SIZE

  # EIP
  MaxPrecompilesAddr* =                     0xFFFF

  EXTRA_SEAL* = ##\
    ## Fixed number of suffix bytes reserved for signer seal of the `extraData`
    ## header field. The 65 bytes constant value is for signatures based on the
    ## standard secp256k1 curve.
    65

  DEFAULT_RPC_GAS_CAP* =                    50_000_000.GasInt

  # EIP-4844 constants
  MAX_CALLDATA_SIZE* = 1 shl 24 # 2^24
  MAX_ACCESS_LIST_SIZE* = 1 shl 24 # 2^24
  MAX_ACCESS_LIST_STORAGE_KEYS* = 1 shl 24 # 2^24
  MAX_TX_WRAP_COMMITMENTS* = 1 shl 12 # 2^12
  VERSIONED_HASH_VERSION_KZG* = 0x01.byte
  FIELD_ELEMENTS_PER_BLOB* = 4096
  GAS_PER_BLOB* = (1 shl 17).uint64 # 2^17
  TARGET_BLOB_GAS_PER_BLOCK* = 393216
  MIN_BLOB_GASPRICE* = 1'u64
  BLOB_GASPRICE_UPDATE_FRACTION* = 3338477'u64
  MAX_BLOB_GAS_PER_BLOCK* = 786432
  MAX_BLOBS_PER_BLOCK* = int(MAX_BLOB_GAS_PER_BLOCK div GAS_PER_BLOB)

  # EIP-4788 addresses
  # BEACON_ROOTS_ADDRESS is the address where historical beacon roots are stored as per EIP-4788
  BEACON_ROOTS_ADDRESS* = address"0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02"
  # SYSTEM_ADDRESS is where the system-transaction is sent from as per EIP-4788
  SYSTEM_ADDRESS* = address"0xfffffffffffffffffffffffffffffffffffffffe"

  RIPEMD_ADDR* = block:
    proc initAddress(x: int): EthAddress {.compileTime.} =
      result.data[19] = x.byte
    initAddress(3)

  HISTORY_STORAGE_ADDRESS* = address"0x0aae40965e6800cd9b1f4b05ff21581047e3f91e"
  DEPOSIT_CONTRACT_ADDRESS* = address"0x00000000219ab540356cbb839cbe05303d7705fa"
  WITHDRAWAL_REQUEST_ADDRESS* = address"0x00A3ca265EBcb825B45F985A16CEFB49958cE017"
  CONSOLIDATION_REQUEST_ADDRESS* = address"0x00b42dbF2194e931E80326D950320f7d9Dbeac02"
# End
