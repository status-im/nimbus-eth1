# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/math, nimcrypto/hash, ssz_serialization

from beacon_chain/spec/datatypes/capella import Withdrawal
from beacon_chain/spec/presets/mainnet import MAX_WITHDRAWALS_PER_PAYLOAD

export ssz_serialization, hash

## History network content values:
## https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values

const
  MAX_TRANSACTION_LENGTH = 2 ^ 24 # ~= 16 million
  MAX_TRANSACTION_COUNT = 2 ^ 14 # ~= 16k
  MAX_RECEIPT_LENGTH = 2 ^ 27 # ~= 134 million
  MAX_HEADER_LENGTH = 2 ^ 13 # = 8192
  MAX_ENCODED_UNCLES_LENGTH = MAX_HEADER_LENGTH * 2 ^ 4 # = 2 ^ 17 ~= 131k
  MAX_WITHDRAWAL_LENGTH = 64
  MAX_WITHDRAWALS_COUNT = MAX_WITHDRAWALS_PER_PAYLOAD

type
  ## BlockHeader types
  AccumulatorProof* = array[15, Digest]

  BlockHeaderProofType* = enum
    none = 0x00 # An SSZ Union None
    accumulatorProof = 0x01

  BlockHeaderProof* = object
    case proofType*: BlockHeaderProofType
    of none:
      discard
    of accumulatorProof:
      accumulatorProof*: AccumulatorProof

  BlockHeaderWithProof* = object
    header*: List[byte, 2048] # RLP data
    proof*: BlockHeaderProof

  ## BlockBody types
  TransactionByteList* = List[byte, MAX_TRANSACTION_LENGTH] # RLP data
  Transactions* = List[TransactionByteList, MAX_TRANSACTION_COUNT]

  Uncles* = List[byte, MAX_ENCODED_UNCLES_LENGTH] # RLP data

  WithdrawalByteList* = List[byte, MAX_WITHDRAWAL_LENGTH] # RLP data
  Withdrawals* = List[WithdrawalByteList, MAX_WITHDRAWALS_COUNT]

  # Pre-shanghai block body
  PortalBlockBodyLegacy* = object
    transactions*: Transactions
    uncles*: Uncles # Post Paris/TheMerge, this list is required to be empty

  # Post-shanghai block body
  PortalBlockBodyShanghai* = object
    transactions*: Transactions
    uncles*: Uncles # Must be empty list
    withdrawals*: Withdrawals # new field

  ## Receipts types
  ReceiptByteList* = List[byte, MAX_RECEIPT_LENGTH] # RLP data
  PortalReceipts* = List[ReceiptByteList, MAX_TRANSACTION_COUNT]

func init*(T: type BlockHeaderProof, proof: AccumulatorProof): T =
  BlockHeaderProof(proofType: accumulatorProof, accumulatorProof: proof)

func init*(T: type BlockHeaderProof): T =
  BlockHeaderProof(proofType: none)
