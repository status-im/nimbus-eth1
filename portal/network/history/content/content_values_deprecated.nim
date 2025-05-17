# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/math, nimcrypto/hash, ssz_serialization

export ssz_serialization, hash

const MAX_HEADER_LENGTH = 2 ^ 11 # = 2048

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

  BlockHeaderWithProofDeprecated* = object
    header*: ByteList[MAX_HEADER_LENGTH] # RLP data
    proof*: BlockHeaderProof
