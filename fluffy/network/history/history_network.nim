# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[options, sugar],
  stew/[results, byteutils],
  eth/p2p/discoveryv5/[protocol, node, enr],
  ../../content_db,
  ../wire/portal_protocol,
  ./history_content

const
  HistoryProtocolId* = "portal:history".toBytes()

type HistoryNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentDB*: ContentDB

proc getHandler(contentDB: ContentDB): ContentHandler =
    return (proc (contentKey: history_content.ByteList): ContentResult =
      let contentId = toContentId(contentKey)
      let maybeContent = contentDB.get(contentId)
      if (maybeContent.isSome()):
        ContentResult(kind: ContentFound, content: maybeContent.unsafeGet())
      else:
        ContentResult(kind: ContentMissing, contentId: contentId))

# Further improvements which may be necessary:
# 1. Return proper domain types instead of bytes
# 2. First check if item is in storage instead of doing lookup
# 3. Put item into storage (if in radius) after succesful lookup
proc getContent*(p: HistoryNetwork, key: ContentKey):
    Future[Option[seq[byte]]] {.async.} =
  let
    keyEncoded = encode(key)
    id = toContentId(keyEncoded)
    content = await p.portalProtocol.contentLookup(keyEncoded, id)
  # for now returning bytes, ultimately it would be nice to return proper domain
  # types from here
  return content.map(x => x.asSeq())

proc new*(T: type HistoryNetwork, baseProtocol: protocol.Protocol,
    contentDB: ContentDB , dataRadius = UInt256.high(),
    bootstrapRecords: openarray[Record] = []): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, HistoryProtocolId, getHandler(contentDB), dataRadius,
    bootstrapRecords)

  return HistoryNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc start*(p: HistoryNetwork) =
  p.portalProtocol.start()

proc stop*(p: HistoryNetwork) =
  p.portalProtocol.stop()
