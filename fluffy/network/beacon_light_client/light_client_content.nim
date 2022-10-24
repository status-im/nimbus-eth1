# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  stew/[arrayops, results],
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  nimcrypto/[sha2, hash],
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, common_types, hash

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

  #TODO Following types will need revision and improvements
  LightClientUpdateKey* = object

  LightClientFinalityUpdateKey* = object

  LightClientOptimisticUpdateKey* = object

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

  # Object internal to light_client_content module, which represent what will be
  # published on the wire
  ForkedLightClientBootstrap = object
    forkDigest: ForkDigest
    bootstrap: altair.LightClientBootstrap

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

proc encodeBootstrapForked*(
    fork: ForkDigest,
    bs: altair.LightClientBootstrap): seq[byte] =
  SSZ.encode(ForkedLightClientBootstrap(forkDigest: fork, bootstrap: bs))

proc decodeBootstrapForked*(
    forks: ForkDigests,
    data: openArray[byte]): Result[altair.LightClientBootstrap, string] =

  if len(data) < 4:
    return Result[altair.LightClientBootstrap, string].err("Too short data")

  let
    arr = ForkDigest(array[4, byte].initCopyFrom(data))

    beaconFork = forks.stateForkForDigest(arr).valueOr:
      return Result[altair.LightClientBootstrap, string].err("Unknown fork")

  if beaconFork >= BeaconStateFork.Altair:
    return decodeBootstrap(data.toOpenArray(4, len(data) - 1))
  else:
    return Result[altair.LightClientBootstrap, string].err(
      "LighClient data is avaialable only after Altair fork"
    )
