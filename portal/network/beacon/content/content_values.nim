# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stew/arrayops,
  results,
  beacon_chain/spec/forks,
  ssz_serialization,
  ../../../common/common_types

export ssz_serialization, results

const
  # https://github.com/ethereum/consensus-specs/blob/v1.4.0/specs/altair/light-client/p2p-interface.md#configuration
  MAX_REQUEST_LIGHT_CLIENT_UPDATES* = 128

  # Needed to properly encode List[List[byte, XXX], MAX_REQUEST_LIGHT_CLIENT_UPDATES]
  # based on eth2 MAX_CHUNK_SIZE, light client update should not be bigger than
  # that
  MAX_LIGHT_CLIENT_UPDATE_SIZE* = 1 * 1024 * 1024

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/beacon-chain/beacon-network.md#data-types
type
  # TODO:
  # ForkedLightClientUpdateBytesList can get pretty big and is send in one go.
  # We might need chunking here but that is currently only possible in
  # Portal wire protocol (and only for offer/accept).
  ForkedLightClientUpdateBytes* = List[byte, MAX_LIGHT_CLIENT_UPDATE_SIZE]
  ForkedLightClientUpdateBytesList* =
    List[ForkedLightClientUpdateBytes, MAX_REQUEST_LIGHT_CLIENT_UPDATES]

  # Note: Type not send over the wire, just used internally.
  ForkedLightClientUpdateList* =
    List[ForkedLightClientUpdate, MAX_REQUEST_LIGHT_CLIENT_UPDATES]

func forkDigestAtEpoch*(
    forkDigests: ForkDigests, epoch: Epoch, cfg: RuntimeConfig
): ForkDigest =
  forkDigests.atEpoch(epoch, cfg)

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
    obj: SomeForkedLightClientObject, forkDigest: ForkDigest
): seq[byte] =
  withForkyObject(obj):
    when lcDataFork > LightClientDataFork.None:
      var res: seq[byte]
      res.add(distinctBase(forkDigest))
      res.add(SSZ.encode(forkyObject))

      return res
    else:
      raiseAssert("No light client objects before Altair")

func encodeBootstrapForked*(
    forkDigest: ForkDigest, bootstrap: ForkedLightClientBootstrap
): seq[byte] =
  encodeForkedLightClientObject(bootstrap, forkDigest)

func encodeFinalityUpdateForked*(
    forkDigest: ForkDigest, finalityUpdate: ForkedLightClientFinalityUpdate
): seq[byte] =
  encodeForkedLightClientObject(finalityUpdate, forkDigest)

func encodeOptimisticUpdateForked*(
    forkDigest: ForkDigest, optimisticUpdate: ForkedLightClientOptimisticUpdate
): seq[byte] =
  encodeForkedLightClientObject(optimisticUpdate, forkDigest)

func encodeLightClientUpdatesForked*(
    updates: ForkedLightClientUpdateList, forkDigests: ForkDigests, cfg: RuntimeConfig
): seq[byte] =
  var list: ForkedLightClientUpdateBytesList
  for update in updates:
    withForkyObject(update):
      when lcDataFork > LightClientDataFork.None:
        let slot = forkyObject.attested_header.beacon.slot
        let forkDigest = forkDigestAtEpoch(forkDigests, epoch(slot), cfg)

        discard list.add(
          ForkedLightClientUpdateBytes(
            encodeForkedLightClientObject(update, forkDigest)
          )
        )

  SSZ.encode(list)

func decodeForkedLightClientObject(
    ObjType: type SomeForkedLightClientObject,
    forkDigests: ForkDigests,
    data: openArray[byte],
): Result[ObjType, string] =
  if len(data) < 4:
    return Result[ObjType, string].err("Not enough data for forkDigest")

  let
    forkDigest = ForkDigest(array[4, byte].initCopyFrom(data))
    contextFork = forkDigests.consensusForkForDigest(forkDigest).valueOr:
      return Result[ObjType, string].err("Unknown fork")

  withLcDataFork(lcDataForkAtConsensusFork(contextFork)):
    when lcDataFork > LightClientDataFork.None:
      let res = decodeSsz(data.toOpenArray(4, len(data) - 1), ObjType.Forky(lcDataFork))
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
    forkDigests: ForkDigests, data: openArray[byte]
): Result[ForkedLightClientBootstrap, string] =
  decodeForkedLightClientObject(ForkedLightClientBootstrap, forkDigests, data)

func decodeLightClientUpdateForked*(
    forkDigests: ForkDigests, data: openArray[byte]
): Result[ForkedLightClientUpdate, string] =
  decodeForkedLightClientObject(ForkedLightClientUpdate, forkDigests, data)

func decodeLightClientFinalityUpdateForked*(
    forkDigests: ForkDigests, data: openArray[byte]
): Result[ForkedLightClientFinalityUpdate, string] =
  decodeForkedLightClientObject(ForkedLightClientFinalityUpdate, forkDigests, data)

func decodeLightClientOptimisticUpdateForked*(
    forkDigests: ForkDigests, data: openArray[byte]
): Result[ForkedLightClientOptimisticUpdate, string] =
  decodeForkedLightClientObject(ForkedLightClientOptimisticUpdate, forkDigests, data)

func decodeLightClientUpdatesByRange*(
    forkDigests: ForkDigests, data: openArray[byte]
): Result[ForkedLightClientUpdateList, string] =
  let list = ?decodeSsz(data, ForkedLightClientUpdateBytesList)

  var res: ForkedLightClientUpdateList
  for encodedUpdate in list:
    let update = ?decodeLightClientUpdateForked(forkDigests, encodedUpdate.asSeq())
    discard res.add(update)

  ok(res)
