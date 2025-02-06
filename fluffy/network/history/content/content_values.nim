# fluffy
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/math, nimcrypto/hash, ssz_serialization

from beacon_chain/spec/presets/mainnet import MAX_WITHDRAWALS_PER_PAYLOAD

export ssz_serialization, hash

## History network content values:
## https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values

const
  MAX_TRANSACTION_LENGTH = 2 ^ 24 # ~= 16 million
  MAX_TRANSACTION_COUNT = 2 ^ 14 # ~= 16k
  MAX_RECEIPT_LENGTH = 2 ^ 27 # ~= 134 million
  MAX_HEADER_LENGTH* = 2 ^ 11 # = 2048
  MAX_ENCODED_UNCLES_LENGTH = MAX_HEADER_LENGTH * 2 ^ 4 # = 2 ^ 17 ~= 131k
  MAX_WITHDRAWAL_LENGTH = 64
  MAX_WITHDRAWALS_COUNT = MAX_WITHDRAWALS_PER_PAYLOAD

  MAX_EPHEMERAL_HEADER_PAYLOAD = 256

type
  ## BlockHeader types
  HistoricalHashesAccumulatorProof* = array[15, Digest]

  BlockHeaderProofType* = enum
    none = 0x00 # An SSZ Union None
    historicalHashesAccumulatorProof = 0x01

  BlockHeaderProof* = object
    case proofType*: BlockHeaderProofType
    of none:
      discard
    of historicalHashesAccumulatorProof:
      historicalHashesAccumulatorProof*: HistoricalHashesAccumulatorProof

  BlockHeaderWithProof* = object
    header*: ByteList[MAX_HEADER_LENGTH] # RLP data
    proof*: BlockHeaderProof

  ## Ephemeral BlockHeader list
  EphemeralBlockHeaderList* =
    List[ByteList[MAX_HEADER_LENGTH], MAX_EPHEMERAL_HEADER_PAYLOAD]

  ## BlockBody types
  TransactionByteList* = ByteList[MAX_TRANSACTION_LENGTH] # RLP data
  Transactions* = List[TransactionByteList, MAX_TRANSACTION_COUNT]

  Uncles* = ByteList[MAX_ENCODED_UNCLES_LENGTH] # RLP data

  WithdrawalByteList* = ByteList[MAX_WITHDRAWAL_LENGTH] # RLP data
  Withdrawals* = List[WithdrawalByteList, MAX_WITHDRAWALS_COUNT]

  # Pre-shanghai block body
  PortalBlockBodyLegacy* = object
    transactions*: Transactions
    uncles*: Uncles # Post Paris/TheMerge, this RLP list must be empty

  # Post-shanghai block body
  PortalBlockBodyShanghai* = object
    transactions*: Transactions
    uncles*: Uncles # Must be empty RLP list
    withdrawals*: Withdrawals # new field

  ## Receipts types
  ReceiptByteList* = ByteList[MAX_RECEIPT_LENGTH] # RLP data
  PortalReceipts* = List[ReceiptByteList, MAX_TRANSACTION_COUNT]

func init*(T: type BlockHeaderProof, proof: HistoricalHashesAccumulatorProof): T =
  BlockHeaderProof(
    proofType: historicalHashesAccumulatorProof, historicalHashesAccumulatorProof: proof
  )

func init*(T: type BlockHeaderProof): T =
  BlockHeaderProof(proofType: none)
