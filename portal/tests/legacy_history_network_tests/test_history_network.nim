# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  testutils/unittests,
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  eth/common/[hashes, headers_rlp, blocks],
  ../../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../../network/legacy_history/[
    history_network,
    history_content,
    validation/block_proof_historical_hashes_accumulator,
  ],
  ../../database/content_db,
  ../../network/beacon/beacon_init_loader,
  ../test_helpers,
  ./test_history_util

type HistoryNode = ref object
  discv5*: discv5_protocol.Protocol
  historyNetwork*: LegacyHistoryNetwork

proc newHistoryNode(
    rng: ref HmacDrbgContext,
    port: int,
    accumulator: FinishedHistoricalHashesAccumulator,
): HistoryNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new(
      "", uint32.high, RadiusConfig(kind: Dynamic), node.localNode.id, inMemory = true
    )
    streamManager = StreamManager.new(node)
    networkData = loadNetworkData("mainnet")
    cfg = networkData.metadata.cfg
    historyNetwork = LegacyHistoryNetwork.new(
      PortalNetwork.none, node, db, streamManager, cfg, accumulator
    )

  return HistoryNode(discv5: node, historyNetwork: historyNetwork)

proc portalProtocol(hn: HistoryNode): PortalProtocol =
  hn.historyNetwork.portalProtocol

proc localNode(hn: HistoryNode): Node =
  hn.discv5.localNode

proc start(hn: HistoryNode) =
  hn.historyNetwork.start()

proc stop(hn: HistoryNode) {.async.} =
  discard hn.historyNetwork.stop()
  await hn.discv5.closeWait()

proc containsId(hn: HistoryNode, contentId: ContentId): bool =
  hn.historyNetwork.contentDB.contains(contentId)

proc checkContainsIdWithRetry(
    historyNode: HistoryNode, id: ContentId
) {.async: (raises: [CancelledError]).} =
  var res = false
  for i in 0 .. 50:
    res = historyNode.containsId(id)
    if res:
      break
    await sleepAsync(10.milliseconds)

  check res

proc createEmptyHeaders(fromNum: int, toNum: int): seq[Header] =
  var headers: seq[Header]
  for i in fromNum .. toNum:
    var bh = Header()
    bh.number = i.uint64
    bh.difficulty = u256(i)
    # empty so that we won't care about creating fake block bodies
    bh.ommersHash = EMPTY_UNCLE_HASH
    bh.transactionsRoot = emptyRoot
    headers.add(bh)
  return headers

proc headersToContentKV(headersWithProof: seq[BlockHeaderWithProof]): seq[ContentKV] =
  var contentKVs: seq[ContentKV]
  for headerWithProof in headersWithProof:
    let
      # TODO: Decoding step could be avoided
      header = rlp.decode(headerWithProof.header.asSeq(), Header)
      headerHash = header.computeRlpHash()
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
        EPOCH_SIZE - 1,
        EPOCH_SIZE,
        EPOCH_SIZE * 2 - 1,
        EPOCH_SIZE * 2,
        EPOCH_SIZE * 3 - 1,
        EPOCH_SIZE * 3,
        EPOCH_SIZE * 3 + 1,
        int(lastBlockNumber),
      ]

    let headers = createEmptyHeaders(0, int(lastBlockNumber))
    let accumulatorRes = buildAccumulatorData(headers)
    check accumulatorRes.isOk()

    let
      (masterAccumulator, epochRecords) = accumulatorRes.get()
      historyNode1 = newHistoryNode(rng, 20302, masterAccumulator)
      historyNode2 = newHistoryNode(rng, 20303, masterAccumulator)

    var selectedHeaders: seq[Header]
    for i in headersToTest:
      selectedHeaders.add(headers[i])

    let headersWithProof = buildHeadersWithProof(selectedHeaders, epochRecords)

    check headersWithProof.isOk()

    # Only node 2 stores the headers (by number)
    for headerWithProof in headersWithProof.get():
      let
        header = rlp.decode(headerWithProof.header.asSeq(), Header)
        contentKey = blockHeaderContentKey(header.number)
        encKey = encode(contentKey)
        contentId = toContentId(contentKey)
      historyNode2.portalProtocol().storeContent(
        encKey, contentId, SSZ.encode(headerWithProof)
      )

    check:
      historyNode1.portalProtocol().addNode(historyNode2.localNode()) == Added
      historyNode2.portalProtocol().addNode(historyNode1.localNode()) == Added

      (await historyNode1.portalProtocol().ping(historyNode2.localNode())).isOk()
      (await historyNode2.portalProtocol().ping(historyNode1.localNode())).isOk()

    for i in headersToTest:
      let blockResponse = await historyNode1.historyNetwork.getBlock(i.uint64)

      check blockResponse.isOk()

      let (blockHeader, blockBody) = blockResponse.value()

      check blockHeader == headers[i]

    await historyNode1.stop()
    await historyNode2.stop()

  asyncTest "Offer - Maximum plus one Content Keys in 1 Message":
    # Need to provide enough headers to have the accumulator "finished".
    const lastBlockNumber = int(mergeBlockNumber - 1)

    let headers = createEmptyHeaders(0, lastBlockNumber)
    let accumulatorRes = buildAccumulatorData(headers)
    check accumulatorRes.isOk()

    let
      (masterAccumulator, epochRecords) = accumulatorRes.get()
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
      buildHeadersWithProof(headers[0 .. maxOfferedHistoryContent], epochRecords)
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
    let offerResult =
      await historyNode1.portalProtocol.offer(historyNode2.localNode(), contentKVs)

    # Fail due timeout, as remote side must drop the too large discv5 packet
    check offerResult.isErr()

    for contentKV in contentKVs:
      let id = toContentId(contentKV.contentKey)
      check historyNode2.containsId(id) == false

    await historyNode1.stop()
    await historyNode2.stop()

  asyncTest "Offer - Maximum Content Keys in 1 Message":
    # Need to provide enough headers to have the accumulator "finished".
    const lastBlockNumber = int(mergeBlockNumber - 1)

    let headers = createEmptyHeaders(0, lastBlockNumber)
    let accumulatorRes = buildAccumulatorData(headers)
    check accumulatorRes.isOk()

    let
      (masterAccumulator, epochRecords) = accumulatorRes.get()
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
      buildHeadersWithProof(headers[0 ..< maxOfferedHistoryContent], epochRecords)
    check headersWithProof.isOk()

    # This is equal to maxOfferedHistoryContent
    let contentKVs = headersToContentKV(headersWithProof.get())

    # node 1 will offer the content so it needs to have it in its database
    for contentKV in contentKVs:
      let id = toContentId(contentKV.contentKey)
      historyNode1.portalProtocol.storeContent(
        contentKV.contentKey, id, contentKV.content
      )

    # One content key less should make offer be succesful and should result
    # in the content being transferred and stored on the other node.
    let offerResult = await historyNode1.portalProtocol.offer(
      historyNode2.localNode(), contentKVs[0 ..< maxOfferedHistoryContent]
    )

    check offerResult.isOk()

    # Make sure the content got processed out of content queue
    while not historyNode2.historyNetwork.contentQueue.empty():
      await sleepAsync(1.milliseconds)

    for i, contentKV in contentKVs:
      let id = toContentId(contentKV.contentKey)
      await historyNode2.checkContainsIdWithRetry(id)

    await historyNode1.stop()
    await historyNode2.stop()

  asyncTest "Offer - Headers with No Historical Epochs - Stopped at Merge Block":
    const
      lastBlockNumber = int(mergeBlockNumber - 1)
      headersToTest =
        [0, 1, EPOCH_SIZE div 2, EPOCH_SIZE - 1, lastBlockNumber - 1, lastBlockNumber]

    let headers = createEmptyHeaders(0, lastBlockNumber)
    let accumulatorRes = buildAccumulatorData(headers)
    check accumulatorRes.isOk()

    let
      (masterAccumulator, epochRecords) = accumulatorRes.get()
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

    var selectedHeaders: seq[Header]
    for i in headersToTest:
      selectedHeaders.add(headers[i])

    let headersWithProof = buildHeadersWithProof(selectedHeaders, epochRecords)
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

    for contentKV in contentKVs:
      let id = toContentId(contentKV.contentKey)
      await historyNode2.checkContainsIdWithRetry(id)

    await historyNode1.stop()
    await historyNode2.stop()
