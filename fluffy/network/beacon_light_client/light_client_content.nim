# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, typetraits],
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

  # TODO Consider how we will gossip bootstraps?
  # In normal LC operation node trust only one offered bootstrap, therefore offers
  # of any other bootstraps would be rejected.
  LightClientBootstrapKey* = object
    blockHash*: Digest

  LightClientUpdateKey* = object
    startPeriod*: uint64
    count*: uint64

  # TODO Following types are not yet included in spec
  # optimisticSlot - slot of attested header of the update
  # finalSlot - slot of finalized header of the update
  LightClientFinalityUpdateKey* = object
    optimisticSlot: uint64
    finalSlot: uint64

  # optimisticSlot - slot of attested header of the update
  LightClientOptimisticUpdateKey* = object
    optimisticSlot: uint64

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

  ForkedLightClientUpdateBytes* = List[byte, MAX_LIGHT_CLIENT_UPDATE_SIZE]
  LightClientUpdateList* = List[ForkedLightClientUpdateBytes, MAX_REQUEST_LIGHT_CLIENT_UPDATES]

func encode*(contentKey: ContentKey): ByteList =
  ByteList.init(SSZ.encode(contentKey))

func decode*(contentKey: ByteList): Option[ContentKey] =
  try:
    some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SszError:
    return none[ContentKey]()

func toContentId*(contentKey: ByteList): ContentId =
  # TODO: Should we try to parse the content key here for invalid ones?
  let idHash = sha2.sha256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))

proc decodeBootstrap(
    data: openArray[byte]): Result[altair.LightClientBootstrap, string] =
  try:
    let decoded = SSZ.decode(
      data,
      altair.LightClientBootstrap
    )
    return ok(decoded)
  except SszError as exc:
    return err(exc.msg)

proc decodeLighClientObject(
    ObjType: type altair.SomeLightClientObject,
    data: openArray[byte]): Result[ObjType, string] =
  try:
    let decoded = SSZ.decode(
      data,
      ObjType
    )
    return ok(decoded)
  except SszError as exc:
    return err(exc.msg)

proc encodeForked*(
    ObjType: type altair.SomeLightClientObject,
    fork: ForkDigest,
    obj: ObjType): seq[byte] =
  # TODO probably not super efficient
  let arr = distinctBase(fork)
  let enc = SSZ.encode(obj)
  return concat(@arr, enc)

proc encodeBootstrapForked*(
    fork: ForkDigest,
    bs: altair.LightClientBootstrap): seq[byte] =
  return encodeForked(altair.LightClientBootstrap, fork, bs)

proc encodeFinalityUpdateForked*(
    fork: ForkDigest,
    update: altair.LightClientFinalityUpdate): seq[byte] =
  return encodeForked(altair.LightClientFinalityUpdate, fork, update)

proc encodeOptimisticUpdateForked*(
    fork: ForkDigest,
    update: altair.LightClientOptimisticUpdate): seq[byte] =
  return encodeForked(altair.LightClientOptimisticUpdate, fork, update)

proc decodeForkedLightClientObject(
    ObjType: type altair.SomeLightClientObject,
    forks: ForkDigests,
    data: openArray[byte]): Result[ObjType, string] =
  if len(data) < 4:
    return Result[ObjType, string].err("Too short data")

  let
    arr = ForkDigest(array[4, byte].initCopyFrom(data))

    beaconFork = forks.stateForkForDigest(arr).valueOr:
      return Result[ObjType, string].err("Unknown fork")

  if beaconFork >= BeaconStateFork.Altair:
    return decodeLighClientObject(ObjType, data.toOpenArray(4, len(data) - 1))
  else:
    return Result[ObjType, string].err(
      "LighClient data is avaialable only after Altair fork"
    )

proc decodeBootstrapForked*(
    forks: ForkDigests,
    data: openArray[byte]): Result[altair.LightClientBootstrap, string] =
  return decodeForkedLightClientObject(
    altair.LightClientBootstrap,
    forks,
    data
  )

proc decodeLightClientUpdateForked*(
    forks: ForkDigests,
    data: openArray[byte]): Result[altair.LightClientUpdate, string] =
  return decodeForkedLightClientObject(
    altair.LightClientUpdate,
    forks,
    data
  )

proc decodeLightClientFinalityUpdateForked*(
    forks: ForkDigests,
    data: openArray[byte]): Result[altair.LightClientFinalityUpdate, string] =
  return decodeForkedLightClientObject(
    altair.LightClientFinalityUpdate,
    forks,
    data
  )

proc decodeLightClientOptimisticUpdateForked*(
    forks: ForkDigests,
    data: openArray[byte]): Result[altair.LightClientOptimisticUpdate, string] =
  return decodeForkedLightClientObject(
    altair.LightClientOptimisticUpdate,
    forks,
    data
  )

proc encodeLightClientUpdatesForked*(
    fork: ForkDigest,
    objects: openArray[altair.LightClientUpdate]
): seq[byte] =
  var lu: LightClientUpdateList
  for obj in objects:
    discard lu.add(
      ForkedLightClientUpdateBytes(encodeForked(altair.LightClientUpdate, fork, obj))
    )

  return SSZ.encode(lu)

proc decodeLightClientUpdatesForkedAsList*(
    data: openArray[byte]): Result[LightClientUpdateList, string] =
  try:
    let listDecoded = SSZ.decode(
      data,
      LightClientUpdateList
    )
    return ok(listDecoded)
  except SszError as exc:
    return err(exc.msg)

proc decodeLightClientUpdatesForked*(
    forks: ForkDigests,
    data: openArray[byte]): Result[seq[altair.LightClientUpdate], string] =
  let listDecoded = ? decodeLightClientUpdatesForkedAsList(data)

  var updates: seq[altair.LightClientUpdate]

  for enc in listDecoded:
    let updateDecoded = ? decodeLightClientUpdateForked(forks, enc.asSeq())
    updates.add(updateDecoded)

  return ok(updates)


func bootstrapContentKey*(bh: Digest): ContentKey =
  ContentKey(
    contentType: lightClientBootstrap,
    lightClientBootstrapKey: LightClientBootstrapKey(blockHash: bh)
  )

func updateContentKey*(startPeriod: uint64, count: uint64): ContentKey =
  ContentKey(
    contentType: lightClientUpdate,
    lightClientUpdateKey: LightClientUpdateKey(startPeriod: startPeriod, count: count)
  )

func finalityUpdateContentKey*(finalSlot: uint64, optimisticSlot: uint64): ContentKey =
  ContentKey(
    contentType: lightClientFinalityUpdate,
    lightClientFinalityUpdateKey: LightClientFinalityUpdateKey(
      optimisticSlot: optimisticSlot,
      finalSlot: finalSlot
    )
  )

func optimisticUpdateContentKey*(optimisticSlot: uint64): ContentKey =
  ContentKey(
    contentType: lightClientOptimisticUpdate,
    lightClientOptimisticUpdateKey: LightClientOptimisticUpdateKey(
      optimisticSlot: optimisticSlot
    )
  )
