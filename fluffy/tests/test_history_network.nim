# Fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  testutils/unittests,
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  eth/common/eth_types_rlp,
  eth/rlp,
  ../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../network/history/[history_network, accumulator, history_content],
  ../database/content_db,
  ./test_helpers

type HistoryNode = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  historyNetwork*: HistoryNetwork

proc newHistoryNode(
    rng: ref HmacDrbgContext, port: int, accumulator: FinishedAccumulator
): HistoryNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new("", uint32.high, inMemory = true)
    streamManager = StreamManager.new(node)
    historyNetwork =
      HistoryNetwork.new(PortalNetwork.none, node, db, streamManager, accumulator)

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
  for i in fromNum .. toNum:
    var bh = BlockHeader()
    bh.number = BlockNumber(i)
    bh.difficulty = u256(i)
    # empty so that we won't care about creating fake block bodies
    bh.ommersHash = EMPTY_UNCLE_HASH
    bh.txRoot = EMPTY_ROOT_HASH
    headers.add(bh)
  return headers

proc headersToContentKV(headersWithProof: seq[BlockHeaderWithProof]): seq[ContentKV] =
  var contentKVs: seq[ContentKV]
  for headerWithProof in headersWithProof:
    let
      # TODO: Decoding step could be avoided
      header = rlp.decode(headerWithProof.header.asSeq(), BlockHeader)
      headerHash = header.blockHash()
      blockKey = BlockKey(blockHash: headerHash)
      contentKey =
        encode(ContentKey(contentType: blockHeader, blockHeaderKey: blockKey))
      contentKV =
        ContentKV(contentKey: contentKey, content: SSZ.encode(headerWithProof))
    contentKVs.add(contentKV)
  return contentKVs

procSuite "History Content Network":
  let rng = newRng()

  asyncTest "Get Block by Number":
    const
      lastBlockNumber = mergeBlockNumber - 1

      headersToTest = [
        0,
        epochSize - 1,
        epochSize,
        epochSize * 2 - 1,
        epochSize * 2,
        epochSize * 3 - 1,
        epochSize * 3,
        epochSize * 3 + 1,
        int(lastBlockNumber),
      ]

    let headers = createEmptyHeaders(0, int(lastBlockNumber))
    let accumulatorRes = buildAccumulatorData(headers)
    check accumulatorRes.isOk()

    let
      (masterAccumulator, epochAccumulators) = accumulatorRes.get()
      historyNode1 = newHistoryNode(rng, 20302, masterAccumulator)
      historyNode2 = newHistoryNode(rng, 20303, masterAccumulator)

    var selectedHeaders: seq[BlockHeader]
    for i in headersToTest:
      selectedHeaders.add(headers[i])

    let headersWithProof = buildHeadersWithProof(selectedHeaders, epochAccumulators)

    check headersWithProof.isOk()

    # Only node 2 stores the headers and all epoch accumulators.
    for headerWithProof in headersWithProof.get():
      let
        header = rlp.decode(headerWithProof.header.asSeq(), BlockHeader)
        headerHash = header.blockHash()
        blockKey = BlockKey(blockHash: headerHash)
        contentKey = ContentKey(contentType: blockHeader, blockHeaderKey: blockKey)
        encKey = encode(contentKey)
        contentId = toContentId(contentKey)
      historyNode2.portalProtocol().storeContent(
        encKey, contentId, SSZ.encode(headerWithProof)
      )

    # Need to store the epoch accumulators to be able to do the block to hash
    # mapping
    for epochAccumulator in epochAccumulators:
      let
        rootHash = epochAccumulator.hash_tree_root()
        contentKey = ContentKey(
          contentType: ContentType.epochAccumulator,
          epochAccumulatorKey: EpochAccumulatorKey(epochHash: rootHash),
        )
        encKey = encode(contentKey)
        contentId = toContentId(contentKey)
      historyNode2.portalProtocol().storeContent(
        encKey, contentId, SSZ.encode(epochAccumulator)
      )

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

    let headers = createEmptyHeaders(0, lastBlockNumber)
    let accumulatorRes = buildAccumulatorData(headers)
    check accumulatorRes.isOk()

    let
      (masterAccumulator, epochAccumulators) = accumulatorRes.get()
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

    let maxOfferedHistoryContent =
      getMaxOfferedContentKeys(uint32(len(PortalProtocolId)), maxContentKeySize)

    let headersWithProof =
      buildHeadersWithProof(headers[0 .. maxOfferedHistoryContent], epochAccumulators)
    check headersWithProof.isOk()

    # This is one header more than maxOfferedHistoryContent
    let contentKVs = headersToContentKV(headersWithProof.get())

    # node 1 will offer the content so it needs to have it in its database
    for contentKV in contentKVs:
      let id = toContentId(contentKV.contentKey)
      historyNode1.portalProtocol.storeContent(
        contentKV.contentKey, id, contentKV.content
      )

    # Offering 1 content item too much which should result in a discv5 packet
    # that is too large and thus not get any response.
    block:
      let offerResult =
        await historyNode1.portalProtocol.offer(historyNode2.localNode(), contentKVs)

      # Fail due timeout, as remote side must drop the too large discv5 packet
      check offerResult.isErr()

      for contentKV in contentKVs:
        let id = toContentId(contentKV.contentKey)
        check historyNode2.containsId(id) == false

    # One content key less should make offer be succesful and should result
    # in the content being transferred and stored on the other node.
    block:
      let offerResult = await historyNode1.portalProtocol.offer(
        historyNode2.localNode(), contentKVs[0 ..< maxOfferedHistoryContent]
      )

      check offerResult.isOk()

      # Make sure the content got processed out of content queue
      while not historyNode2.historyNetwork.contentQueue.empty():
        await sleepAsync(1.milliseconds)

      # Note: It seems something changed in chronos, causing different behavior.
      # Seems that validateContent called through processContentLoop used to
      # run immediatly in case of a "non async shortpath". This is no longer the
      # case and causes the content not yet to be validated and thus stored at
      # this step. Add an await here so that the store can happen.
      await sleepAsync(100.milliseconds)

      for i, contentKV in contentKVs:
        let id = toContentId(contentKV.contentKey)
        if i < len(contentKVs) - 1:
          check historyNode2.containsId(id) == true
        else:
          check historyNode2.containsId(id) == false

    await historyNode1.stop()
    await historyNode2.stop()

  asyncTest "Offer - Headers with No Historical Epochs - Stopped at Merge Block":
    const
      lastBlockNumber = int(mergeBlockNumber - 1)
      headersToTest =
        [0, 1, epochSize div 2, epochSize - 1, lastBlockNumber - 1, lastBlockNumber]

    let headers = createEmptyHeaders(0, lastBlockNumber)
    let accumulatorRes = buildAccumulatorData(headers)
    check accumulatorRes.isOk()

    let
      (masterAccumulator, epochAccumulators) = accumulatorRes.get()
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

    var selectedHeaders: seq[BlockHeader]
    for i in headersToTest:
      selectedHeaders.add(headers[i])

    let headersWithProof = buildHeadersWithProof(selectedHeaders, epochAccumulators)
    check headersWithProof.isOk()

    let contentKVs = headersToContentKV(headersWithProof.get())

    for contentKV in contentKVs:
      let id = toContentId(contentKV.contentKey)
      historyNode1.portalProtocol.storeContent(
        contentKV.contentKey, id, contentKV.content
      )

      let offerResult =
        await historyNode1.portalProtocol.offer(historyNode2.localNode(), @[contentKV])

      check offerResult.isOk()

    # Make sure the content got processed out of content queue
    while not historyNode2.historyNetwork.contentQueue.empty():
      await sleepAsync(1.milliseconds)

    await sleepAsync(100.milliseconds)

    for contentKV in contentKVs:
      let id = toContentId(contentKV.contentKey)
      check historyNode2.containsId(id) == true

    await historyNode1.stop()
    await historyNode2.stop()
