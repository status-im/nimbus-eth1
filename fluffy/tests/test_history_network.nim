# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  testutils/unittests, chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/routing_table,
  eth/common/eth_types_rlp,
  eth/rlp,
  ../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../network/history/[history_network, accumulator, history_content],
  ../../nimbus/constants,
  ../content_db,
  ./test_helpers

type HistoryNode = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  historyNetwork*: HistoryNetwork

proc newHistoryNode(rng: ref HmacDrbgContext, port: int,
    accumulator: FinishedAccumulator): HistoryNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new("", uint32.high, inMemory = true)
    streamManager = StreamManager.new(node)
    historyNetwork = HistoryNetwork.new(node, db, streamManager, accumulator)

  return HistoryNode(discoveryProtocol: node, historyNetwork: historyNetwork)

proc portalProtocol(hn: HistoryNode): PortalProtocol =
  hn.historyNetwork.portalProtocol

proc localNode(hn: HistoryNode): Node =
  hn.discoveryProtocol.localNode

proc start(hn: HistoryNode) =
  hn.historyNetwork.start()

proc stop(hn: HistoryNode) {.async.} =
  hn.historyNetwork.stop()
  await hn.discoveryProtocol.closeWait()

proc containsId(hn: HistoryNode, contentId: ContentId): bool =
  return hn.historyNetwork.contentDB.get(contentId).isSome()

proc createEmptyHeaders(fromNum: int, toNum: int): seq[BlockHeader] =
  var headers: seq[BlockHeader]
  for i in fromNum..toNum:
    var bh = BlockHeader()
    bh.blockNumber = u256(i)
    bh.difficulty = u256(i)
    # empty so that we won't care about creating fake block bodies
    bh.ommersHash = EMPTY_UNCLE_HASH
    bh.txRoot = EMPTY_ROOT_HASH
    headers.add(bh)
  return headers

proc headersToContentInfo(headers: seq[BlockHeader]): seq[ContentInfo] =
  var contentInfos: seq[ContentInfo]
  for h in headers:
    let
      headerHash = h.blockHash()
      bk = BlockKey(blockHash: headerHash)
      ck = encode(ContentKey(contentType: blockHeader, blockHeaderKey: bk))
      headerEncoded = rlp.encode(h)
      ci = ContentInfo(contentKey: ck, content: headerEncoded)
    contentInfos.add(ci)
  return contentInfos

procSuite "History Content Network":
  let rng = newRng()

  asyncTest "Get Block by Number":
    const
      lastBlockNumber = mergeBlockNumber - 1

      headersToTest = [
        0,
        epochSize - 1,
        epochSize,
        epochSize*2 - 1,
        epochSize*2,
        epochSize*3 - 1,
        epochSize*3,
        epochSize*3 + 1,
        int(lastBlockNumber)]

    let
      headers = createEmptyHeaders(0, int(lastBlockNumber))
      masterAccumulator = buildAccumulator(headers).get()
      epochAccumulators = buildAccumulatorData(headers)
      historyNode1 = newHistoryNode(rng, 20302, masterAccumulator)
      historyNode2 = newHistoryNode(rng, 20303, masterAccumulator)

    # Only node 2 stores all headers and all epoch accumulators.
    for h in headers:
      let
        headerHash = h.blockHash()
        blockKey = BlockKey(blockHash: headerHash)
        contentKey = ContentKey(
          contentType: blockHeader, blockHeaderKey: blockKey)
        contentId = toContentId(contentKey)
        headerEncoded = rlp.encode(h)
      historyNode2.portalProtocol().storeContent(contentId, headerEncoded)

    for (contentKey, epochAccumulator) in epochAccumulators:
      let contentId = toContentId(contentKey)
      historyNode2.portalProtocol().storeContent(
        contentId, SSZ.encode(epochAccumulator))

    check:
      historyNode1.portalProtocol().addNode(historyNode2.localNode()) == Added
      historyNode2.portalProtocol().addNode(historyNode1.localNode()) == Added

      (await historyNode1.portalProtocol().ping(historyNode2.localNode())).isOk()
      (await historyNode2.portalProtocol().ping(historyNode1.localNode())).isOk()

    for i in headersToTest:
      let blockResponse = await historyNode1.historyNetwork.getBlock(u256(i))

      check blockResponse.isOk()

      let blockOpt = blockResponse.get()

      check blockOpt.isSome()

      let (blockHeader, blockBody) = blockOpt.unsafeGet()

      check blockHeader == headers[i]

    await historyNode1.stop()
    await historyNode2.stop()

  asyncTest "Offer - Maximum Content Keys in 1 Message":
    # Need to provide enough headers to have the accumulator "finished".
    const lastBlockNumber = int(mergeBlockNumber - 1)

    let
      headers = createEmptyHeaders(0, lastBlockNumber)
      masterAccumulator = buildAccumulator(headers).get()
      epochAccumulators = buildAccumulatorData(headers)

      historyNode1 = newHistoryNode(rng, 20302, masterAccumulator)
      historyNode2 = newHistoryNode(rng, 20303, masterAccumulator)

    check:
      historyNode1.portalProtocol().addNode(historyNode2.localNode()) == Added
      historyNode2.portalProtocol().addNode(historyNode1.localNode()) == Added

      (await historyNode1.portalProtocol().ping(historyNode2.localNode())).isOk()
      (await historyNode2.portalProtocol().ping(historyNode1.localNode())).isOk()

    # Need to run start to get the processContentLoop running
    historyNode1.start()
    historyNode2.start()

    let maxOfferedHistoryContent = getMaxOfferedContentKeys(
        uint32(len(historyProtocolId)), maxContentKeySize)

    # One of the nodes needs to have the epochAccumulator to build proofs from
    # for the offered headers.
    for (contentKey, epochAccumulator) in epochAccumulators:
      let contentId = toContentId(contentKey)
      historyNode2.portalProtocol().storeContent(
        contentId, SSZ.encode(epochAccumulator))

    # This is one header more than maxOfferedHistoryContent
    let contentInfos = headersToContentInfo(headers[0..maxOfferedHistoryContent])

    # node 1 will offer the content so it needs to have it in its database
    for contentInfo in contentInfos:
      let id = toContentId(contentInfo.contentKey)
      historyNode1.portalProtocol.storeContent(id, contentInfo.content)

    # Offering 1 content item too much which should result in a discv5 packet
    # that is too large and thus not get any response.
    block:
      let offerResult = await historyNode1.portalProtocol.offer(
        historyNode2.localNode(),
        contentInfos
      )

      # Fail due timeout, as remote side must drop the too large discv5 packet
      check offerResult.isErr()

      for contentInfo in contentInfos:
        let id = toContentId(contentInfo.contentKey)
        check historyNode2.containsId(id) == false

    # One content key less should make offer be succesful and should result
    # in the content being transferred and stored on the other node.
    block:
      let offerResult = await historyNode1.portalProtocol.offer(
        historyNode2.localNode(),
        contentInfos[0..<maxOfferedHistoryContent]
      )

      check offerResult.isOk()

      for i, contentInfo in contentInfos:
        let id = toContentId(contentInfo.contentKey)
        if i < len(contentInfos) - 1:
          check historyNode2.containsId(id) == true
        else:
          check historyNode2.containsId(id) == false

    await historyNode1.stop()
    await historyNode2.stop()

  asyncTest "Offer - Headers with No Historical Epochs - Stopped at Merge Block":
    const
      lastBlockNumber = int(mergeBlockNumber - 1)
      headersToTest = [
        0,
        1,
        epochSize div 2,
        epochSize - 1,
        lastBlockNumber - 1,
        lastBlockNumber]

    let
      headers = createEmptyHeaders(0, lastBlockNumber)
      masterAccumulator = buildAccumulator(headers).get()
      epochAccumulators = buildAccumulatorData(headers)

      historyNode1 = newHistoryNode(rng, 20302, masterAccumulator)
      historyNode2 = newHistoryNode(rng, 20303, masterAccumulator)

    check:
      historyNode1.portalProtocol().addNode(historyNode2.localNode()) == Added
      historyNode2.portalProtocol().addNode(historyNode1.localNode()) == Added

      (await historyNode1.portalProtocol().ping(historyNode2.localNode())).isOk()
      (await historyNode2.portalProtocol().ping(historyNode1.localNode())).isOk()

    # Need to store the epochAccumulators, because else the headers can't be
    # verified if being part of the canonical chain currently
    for (contentKey, epochAccumulator) in epochAccumulators:
      let contentId = toContentId(contentKey)
      historyNode1.portalProtocol.storeContent(
        contentId, SSZ.encode(epochAccumulator))

    # Need to run start to get the processContentLoop running
    historyNode1.start()
    historyNode2.start()

    let contentInfos = headersToContentInfo(headers)

    for header in headersToTest:
      let id = toContentId(contentInfos[header].contentKey)
      historyNode1.portalProtocol.storeContent(id, contentInfos[header].content)

      let offerResult = await historyNode1.portalProtocol.offer(
        historyNode2.localNode(),
        contentInfos[header..header]
      )

      check offerResult.isOk()

    for header in headersToTest:
      let id = toContentId(contentInfos[header].contentKey)
      check historyNode2.containsId(id) == true

    await historyNode1.stop()
    await historyNode2.stop()
