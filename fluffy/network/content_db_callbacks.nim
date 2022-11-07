# Nimbus - Portal Network
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  stew/results,
  chronicles,
  metrics,
  "."/wire/[portal_protocol, portal_protocol_config],
  ../content_db

declareCounter portal_pruning_counter,
  "Number of pruning event which happened during node lifetime",
  labels = ["protocol_id"]

declareGauge portal_pruning_deleted_elements,
  "Number of elements delted in last pruning",
  labels = ["protocol_id"]

proc adjustRadius(
    p: PortalProtocol,
    fractionOfDeletedContent: float64,
    furthestElementInDbDistance: UInt256) =
  if fractionOfDeletedContent == 0.0:
    # even though pruning was triggered no content was deleted, it could happen
    # in pathological case of really small database with really big values.
    # log it as error as it should not happenn
    error "Database pruning attempt resulted in no content deleted"
    return

  # we need to invert fraction as our Uin256 implementation does not support
  # multiplication by float
  let invertedFractionAsInt = int64(1.0 / fractionOfDeletedContent)

  let scaledRadius = p.dataRadius div u256(invertedFractionAsInt)

  # Chose larger value to avoid situation, where furthestElementInDbDistance
  # is super close to local id, so local radius would end up too small
  # to accept any more data to local database
  # If scaledRadius radius will be larger it will still contain all elements
  let newRadius = max(scaledRadius, furthestElementInDbDistance)

  debug "Database pruned",
    oldRadius = p.dataRadius,
    newRadius = newRadius,
    furthestDistanceInDb = furthestElementInDbDistance,
    fractionOfDeletedContent = fractionOfDeletedContent

  # both scaledRadius and furthestElementInDbDistance are smaller than current
  # dataRadius, so the radius will constantly decrease through the node
  # life time
  p.dataRadius = newRadius

proc createGetHandler*(db: ContentDB, toId: ToContentIdHandler): DbGetHandler =
  return (
    proc(contentKey: ByteList): Result[seq[byte], DbError] =
      let maybeId = toId(contentKey)

      if maybeId.isNone():
        return err(DbError(kind: InvalidContentKey))

      let
        id = maybeId.unsafeGet()
        maybeContent = db.get(id)

      if maybeContent.isNone():
        return err(DbError(kind: NoKeyInDb, contentId: id))

      return ok(maybeContent.unsafeGet())
  )

proc createStoreHandler*(db: ContentDB, cfg: RadiusConfig, p: PortalProtocol): PortalStoreHandler =
  return (proc(
      contentKey: ByteList,
      contentId: ContentId,
      content: seq[byte]) {.raises: [Defect], gcsafe.} =
    # always re-check that key is in node range, to make sure that invariant that
    # all keys in database are always in node range hold.
    # TODO current silent assumption is that both contentDb and portalProtocol are
    # using the same xor distance function
    if p.inRange(contentId):
      case cfg.kind:
      of Dynamic:
        # In case of dynamic radius setting we obey storage limits and adjust
        # radius to store network fraction corresponding to those storage limits.
        let res = db.put(contentId, content, p.baseProtocol.localNode.id)
        if res.kind == DbPruned:
          portal_pruning_counter.inc(labelValues = [$p.protocolId])
          portal_pruning_deleted_elements.set(
            res.numOfDeletedElements.int64,
            labelValues = [$p.protocolId]
          )

          p.adjustRadius(
            res.fractionOfDeletedContent,
            res.furthestStoredElementDistance
          )
      of Static:
        # If the config is set statically, radius is not adjusted, and is kept
        # constant thorugh node life time, also database max size is disabled
        # so we will effectivly store fraction of the network
        db.put(contentId, content)
  )
