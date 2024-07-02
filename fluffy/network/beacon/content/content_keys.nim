# fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, nimcrypto/[sha2, hash], ssz_serialization, ../../../common/common_types

export ssz_serialization, common_types, hash

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/beacon-chain/beacon-network.md#data-types

type
  ContentType* = enum
    # Note: See same note as for state/content/content_keys.nim
    unused = 0x00
    lightClientBootstrap = 0x10
    lightClientUpdate = 0x11
    lightClientFinalityUpdate = 0x12
    lightClientOptimisticUpdate = 0x13
    historicalSummaries = 0x14

  # TODO: Consider how we will gossip bootstraps?
  # In consensus light client operation a node trusts only one bootstrap hash,
  # therefore offers of other bootstraps would be rejected.
  LightClientBootstrapKey* = object
    blockHash*: Digest

  LightClientUpdateKey* = object
    startPeriod*: uint64
    count*: uint64

  LightClientFinalityUpdateKey* = object
    finalizedSlot*: uint64 ## slot of finalized header of the update

  LightClientOptimisticUpdateKey* = object
    optimisticSlot*: uint64 ## signature_slot of the update

  HistoricalSummariesKey* = object
    epoch*: uint64

  ContentKey* = object
    case contentType*: ContentType
    of unused:
      discard
    of lightClientBootstrap:
      lightClientBootstrapKey*: LightClientBootstrapKey
    of lightClientUpdate:
      lightClientUpdateKey*: LightClientUpdateKey
    of lightClientFinalityUpdate:
      lightClientFinalityUpdateKey*: LightClientFinalityUpdateKey
    of lightClientOptimisticUpdate:
      lightClientOptimisticUpdateKey*: LightClientOptimisticUpdateKey
    of historicalSummaries:
      historicalSummariesKey*: HistoricalSummariesKey

func encode*(contentKey: ContentKey): ByteList =
  doAssert(contentKey.contentType != unused)
  ByteList.init(SSZ.encode(contentKey))

proc readSszBytes*(data: openArray[byte], val: var ContentKey) {.raises: [SszError].} =
  mixin readSszValue
  if data.len() > 0 and data[0] == ord(unused):
    raise newException(MalformedSszError, "SSZ selector unused value")

  readSszValue(data, val)

func decode*(contentKey: ByteList): Opt[ContentKey] =
  try:
    Opt.some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SerializationError:
    return Opt.none(ContentKey)

func toContentId*(contentKey: ByteList): ContentId =
  # TODO: Should we try to parse the content key here for invalid ones?
  let idHash = sha2.sha256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))

func bootstrapContentKey*(blockHash: Digest): ContentKey =
  ContentKey(
    contentType: lightClientBootstrap,
    lightClientBootstrapKey: LightClientBootstrapKey(blockHash: blockHash),
  )

func updateContentKey*(startPeriod: uint64, count: uint64): ContentKey =
  ContentKey(
    contentType: lightClientUpdate,
    lightClientUpdateKey: LightClientUpdateKey(startPeriod: startPeriod, count: count),
  )

func finalityUpdateContentKey*(finalizedSlot: uint64): ContentKey =
  ContentKey(
    contentType: lightClientFinalityUpdate,
    lightClientFinalityUpdateKey:
      LightClientFinalityUpdateKey(finalizedSlot: finalizedSlot),
  )

func optimisticUpdateContentKey*(optimisticSlot: uint64): ContentKey =
  ContentKey(
    contentType: lightClientOptimisticUpdate,
    lightClientOptimisticUpdateKey:
      LightClientOptimisticUpdateKey(optimisticSlot: optimisticSlot),
  )

func historicalSummariesContentKey*(epoch: uint64): ContentKey =
  ContentKey(
    contentType: historicalSummaries,
    historicalSummariesKey: HistoricalSummariesKey(epoch: epoch),
  )
