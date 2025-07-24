# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  unittest2,
  stew/byteutils,
  chronos/unittest2/asynctests,
  ../../eth_data/yaml_utils,
  ../../tools/eth_data_exporter/el_data_exporter,
  ../../network/wire/portal_protocol,
  ../../network/history/history_network,
  ./history_test_helpers

from eth/common/accounts import EMPTY_ROOT_HASH

const testsPath = "./vendor/portal-spec-tests/tests/mainnet/history/block_data/"

suite "History Network":
  asyncTest "Offer content":
    let
      path = testsPath & "block-data-22869878.yaml"
      blockData = BlockData.loadFromYaml(path).valueOr:
        raiseAssert "Cannot read test vector: " & error

      headerEncoded = blockData.header.hexToSeqByte()
      bodyEncoded = blockData.body.hexToSeqByte()
      header = decodeRlp(headerEncoded, Header).expect("Valid header")
      contentKey = blockBodyContentKey(header.number)
      contentKV = ContentKV(contentKey: contentKey.encode(), content: bodyEncoded)

    proc getHeader(
        blockNumber: uint64
    ): Future[Result[Header, string]] {.async: (raises: [CancelledError]), gcsafe.} =
      if header.number != blockNumber:
        return err(
          "Block number mismatch: expected " & $blockNumber & ", got " & $header.number
        )
      ok(header)

    let
      rng = newRng()
      node1 = newHistoryNetwork(rng, 9001)
      node2 = newHistoryNetwork(rng, 9002, getHeader)

    node1.start()
    node2.start()

    check:
      node1.portalProtocol().addNode(node2.localNode()) == Added
      node2.portalProtocol().addNode(node1.localNode()) == Added

      (await node1.portalProtocol().ping(node2.localNode())).isOk()
      (await node2.portalProtocol().ping(node1.localNode())).isOk()

      # This version of offer does not require to store the content locally
      (await node1.portalProtocol().offer(node2.localNode(), @[contentKV])).isOk()

      node2
      .portalProtocol()
      .getLocalContent(contentKey.encode(), contentKey.toContentId())
      .isSome()

    await node1.stop()
    await node2.stop()

  asyncTest "Offer - Maximum plus one content Keys in 1 message":
    let
      rng = newRng()
      node1 = newHistoryNetwork(rng, 9001)
      node2 = newHistoryNetwork(rng, 9002)

    node1.start()
    node2.start()

    check:
      node1.portalProtocol().addNode(node2.localNode()) == Added
      node2.portalProtocol().addNode(node1.localNode()) == Added

      (await node1.portalProtocol().ping(node2.localNode())).isOk()
      (await node2.portalProtocol().ping(node1.localNode())).isOk()

    var list: seq[ContentKeyByteList]
    for i in 0 ..< contentKeysLimit + 1:
      list.add(blockBodyContentKey(i.uint64).encode())
    # This is invalid way of creating ContentKeysList and will allow to go over the limit
    let contentKeyList = ContentKeysList(list)

    check (await node1.portalProtocol().offer(node2.localNode(), contentKeyList)).isErr()

    await node1.stop()
    await node2.stop()

  asyncTest "Offer - Maximum block bodies in 1 message":
    var count = 0
    proc getHeader(
        blockNumber: uint64
    ): Future[Result[Header, string]] {.async: (raises: [CancelledError]), gcsafe.} =
      count.inc()
      # Return header with correct number and roots filled in for empty blocks
      ok(
        Header(
          number: blockNumber,
          transactionsRoot: EMPTY_ROOT_HASH,
          ommersHash: EMPTY_UNCLE_HASH,
          withdrawalsRoot: Opt.some(EMPTY_ROOT_HASH),
        )
      )

    let
      rng = newRng()
      node1 = newHistoryNetwork(rng, 9001)
      node2 = newHistoryNetwork(rng, 9002, getHeader)

    node1.start()
    node2.start()

    check:
      node1.portalProtocol().addNode(node2.localNode()) == Added
      node2.portalProtocol().addNode(node1.localNode()) == Added

      (await node1.portalProtocol().ping(node2.localNode())).isOk()
      (await node2.portalProtocol().ping(node1.localNode())).isOk()

    # All blocks we send in the test are empty
    let emptyWithdrawals: seq[Withdrawal] = @[]
    let emptyBody = rlp.encode(
      BlockBody(transactions: @[], uncles: @[], withdrawals: Opt.some(emptyWithdrawals))
    )

    var contentKVList: seq[ContentKV]
    for i in 0 ..< contentKeysLimit:
      contentKVList.add(
        ContentKV(
          contentKey: blockBodyContentKey(i.uint64).encode(), content: emptyBody
        )
      )

    check (await node1.portalProtocol().offer(node2.localNode(), contentKVList)).isOk()

    # Wait for contentQueueWorker to process all the content
    while count < contentKeysLimit:
      await sleepAsync(10.milliseconds)

    for contentKV in contentKVList:
      let contentId = contentKV.contentKey.toContentId().expect("Valid content key")
      check node2
      .portalProtocol()
      .getLocalContent(contentKV.contentKey, contentId)
      .isSome()

    await node1.stop()
    await node2.stop()
