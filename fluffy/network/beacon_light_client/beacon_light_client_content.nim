# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/typetraits,
  stew/[arrayops, results],
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  nimcrypto/[sha2, hash],
  ssz_serialization,
  ssz_serialization/codec,
  ../../common/common_types

export ssz_serialization, common_types, hash

# https://github.com/ethereum/consensus-specs/blob/v1.2.0/specs/altair/light-client/p2p-interface.md#configuration
const
  MAX_REQUEST_LIGHT_CLIENT_UPDATES* = 128

  # Needed to properly encode List[List[byte, XXX], MAX_REQUEST_LIGHT_CLIENT_UPDATES]
  # based on eth2 MAX_CHUNK_SIZE, light client update should not be bigger than
  # that
  MAX_LIGHT_CLIENT_UPDATE_SIZE* = 1 * 1024 * 1024

type
  ContentType* = enum
    lightClientBootstrap = 0x00
    lightClientUpdate = 0x01
    lightClientFinalityUpdate = 0x02
    lightClientOptimisticUpdate = 0x03

  # TODO: Consider how we will gossip bootstraps?
  # In consensus light client operation a node trusts only one bootstrap hash,
  # therefore offers of other bootstraps would be rejected.
  LightClientBootstrapKey* = object
    blockHash*: Digest

  LightClientUpdateKey* = object
    startPeriod*: uint64
    count*: uint64

  # TODO:
  # `optimisticSlot` and `finalizedSlot` are currently not in the spec. They are
  # added to avoid accepting them in an offer based on the slot values. However,
  # this causes them also to be included in a request, which makes perhaps less
  # sense?
  LightClientFinalityUpdateKey* = object
    finalizedSlot*: uint64 ## slot of finalized header of the update

  # TODO: Same remark as for `LightClientFinalityUpdateKey`
  LightClientOptimisticUpdateKey* = object
    optimisticSlot*: uint64 ## signature_slot of the update

  ContentKey* = object
    case contentType*: ContentType
    of lightClientBootstrap:
      lightClientBootstrapKey*: LightClientBootstrapKey
    of lightClientUpdate:
      lightClientUpdateKey*: LightClientUpdateKey
    of lightClientFinalityUpdate:
      lightClientFinalityUpdateKey*: LightClientFinalityUpdateKey
    of lightClientOptimisticUpdate:
      lightClientOptimisticUpdateKey*: LightClientOptimisticUpdateKey

  # TODO:
  # ForkedLightClientUpdateBytesList can get pretty big and is send in one go.
  # We will need some chunking here but that is currently only possible in
  # Portal wire protocol (and only for offer/accept).
  ForkedLightClientUpdateBytes* = List[byte, MAX_LIGHT_CLIENT_UPDATE_SIZE]
  ForkedLightClientUpdateBytesList* =
    List[ForkedLightClientUpdateBytes, MAX_REQUEST_LIGHT_CLIENT_UPDATES]
  # Note: Type not send over the wire, just used internally.
  ForkedLightClientUpdateList* =
    List[ForkedLightClientUpdate, MAX_REQUEST_LIGHT_CLIENT_UPDATES]

func encode*(contentKey: ContentKey): ByteList =
  ByteList.init(SSZ.encode(contentKey))

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

# Yes, this API is odd as you pass a SomeForkedLightClientObject yet still have
# to also pass the ForkDigest. This is because we can't just select the right
# digest through the LightClientDataFork here as LightClientDataFork and
# ConsensusFork are not mapped 1-to-1. There is loss of fork data.
# This means we need to get the ConsensusFork directly, which is possible by
# passing the epoch (slot) from the object through `forkDigestAtEpoch`. This
# however requires the runtime config which is part of the `Eth2Node` object.
# Not something we would like to include as a parameter here, so we stick with
# just passing the forkDigest and doing the work outside of this encode call.
func encodeForkedLightClientObject*(
    obj: SomeForkedLightClientObject,
    forkDigest: ForkDigest): seq[byte] =
  withForkyObject(obj):
    when lcDataFork > LightClientDataFork.None:
      var res: seq[byte]
      res.add(distinctBase(forkDigest))
      res.add(SSZ.encode(forkyObject))

      return res
    else:
      raiseAssert("No light client objects before Altair")

func encodeBootstrapForked*(
    forkDigest: ForkDigest,
    bootstrap: ForkedLightClientBootstrap): seq[byte] =
  encodeForkedLightClientObject(bootstrap, forkDigest)

func encodeFinalityUpdateForked*(
    forkDigest: ForkDigest,
    finalityUpdate: ForkedLightClientFinalityUpdate): seq[byte] =
  encodeForkedLightClientObject(finalityUpdate, forkDigest)

func encodeOptimisticUpdateForked*(
    forkDigest: ForkDigest,
    optimisticUpdate: ForkedLightClientOptimisticUpdate): seq[byte] =
  encodeForkedLightClientObject(optimisticUpdate, forkDigest)

func encodeLightClientUpdatesForked*(
    forkDigest: ForkDigest,
    updates: openArray[ForkedLightClientUpdate]): seq[byte] =
  var list: ForkedLightClientUpdateBytesList
  for update in updates:
    discard list.add(
      ForkedLightClientUpdateBytes(
        encodeForkedLightClientObject(update, forkDigest)))

  SSZ.encode(list)

func decodeForkedLightClientObject(
    ObjType: type SomeForkedLightClientObject,
    forkDigests: ForkDigests,
    data: openArray[byte]): Result[ObjType, string] =
  if len(data) < 4:
    return Result[ObjType, string].err("Not enough data for forkDigest")

  let
    forkDigest = ForkDigest(array[4, byte].initCopyFrom(data))
    contextFork = forkDigests.consensusForkForDigest(forkDigest).valueOr:
      return Result[ObjType, string].err("Unknown fork")

  withLcDataFork(lcDataForkAtConsensusFork(contextFork)):
    when lcDataFork > LightClientDataFork.None:
      let res = decodeSsz(
        data.toOpenArray(4, len(data) - 1), ObjType.Forky(lcDataFork))
      if res.isOk:
        # TODO:
        # How can we verify the Epoch vs fork, e.g. with `consensusForkAtEpoch`?
        # And should we?
        var obj = ok ObjType(kind: lcDataFork)
        obj.get.forky(lcDataFork) = res.get
        obj
      else:
        Result[ObjType, string].err(res.error)
    else:
      Result[ObjType, string].err("Invalid Fork")

func decodeLightClientBootstrapForked*(
    forkDigests: ForkDigests,
    data: openArray[byte]): Result[ForkedLightClientBootstrap, string] =
  decodeForkedLightClientObject(
    ForkedLightClientBootstrap,
    forkDigests,
    data
  )

func decodeLightClientUpdateForked*(
    forkDigests: ForkDigests,
    data: openArray[byte]): Result[ForkedLightClientUpdate, string] =
  decodeForkedLightClientObject(
    ForkedLightClientUpdate,
    forkDigests,
    data
  )

func decodeLightClientFinalityUpdateForked*(
    forkDigests: ForkDigests,
    data: openArray[byte]): Result[ForkedLightClientFinalityUpdate, string] =
  decodeForkedLightClientObject(
    ForkedLightClientFinalityUpdate,
    forkDigests,
    data
  )

func decodeLightClientOptimisticUpdateForked*(
    forkDigests: ForkDigests,
    data: openArray[byte]): Result[ForkedLightClientOptimisticUpdate, string] =
  decodeForkedLightClientObject(
    ForkedLightClientOptimisticUpdate,
    forkDigests,
    data
  )

func decodeLightClientUpdatesByRange*(
    forkDigests: ForkDigests,
    data: openArray[byte]):
    Result[ForkedLightClientUpdateList, string] =
  let list = ? decodeSsz(data, ForkedLightClientUpdateBytesList)

  var res: ForkedLightClientUpdateList
  for encodedUpdate in list:
    let update = ? decodeLightClientUpdateForked(
      forkDigests, encodedUpdate.asSeq())
    discard res.add(update)

  ok(res)

func bootstrapContentKey*(blockHash: Digest): ContentKey =
  ContentKey(
    contentType: lightClientBootstrap,
    lightClientBootstrapKey: LightClientBootstrapKey(blockHash: blockHash)
  )

func updateContentKey*(startPeriod: uint64, count: uint64): ContentKey =
  ContentKey(
    contentType: lightClientUpdate,
    lightClientUpdateKey: LightClientUpdateKey(
      startPeriod: startPeriod, count: count)
  )

func finalityUpdateContentKey*(finalizedSlot: uint64): ContentKey =
  ContentKey(
    contentType: lightClientFinalityUpdate,
    lightClientFinalityUpdateKey: LightClientFinalityUpdateKey(
      finalizedSlot: finalizedSlot
    )
  )

func optimisticUpdateContentKey*(optimisticSlot: uint64): ContentKey =
  ContentKey(
    contentType: lightClientOptimisticUpdate,
    lightClientOptimisticUpdateKey: LightClientOptimisticUpdateKey(
      optimisticSlot: optimisticSlot
    )
  )
