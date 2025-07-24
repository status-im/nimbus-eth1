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
  ../../network/history/history_endpoints,
  ./history_test_helpers

from std/os import walkDir, splitFile, PathComponent

const testsPath = "./vendor/portal-spec-tests/tests/mainnet/history/block_data/"

suite "History Network Endpoints":
  asyncTest "GetBlockBody":
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

    for kind, path in walkDir(testsPath):
      if kind == pcFile and path.splitFile.ext == ".yaml":
        let
          blockData = BlockData.loadFromYaml(path).valueOr:
            raiseAssert "Cannot read test vector: " & error

          headerEncoded = blockData.header.hexToSeqByte()
          bodyEncoded = blockData.body.hexToSeqByte()
          header = decodeRlp(headerEncoded, Header).expect("Valid header")
          contentKey = blockBodyContentKey(header.number)

        node1.portalProtocol().storeContent(
          contentKey.encode(), contentKey.toContentId(), bodyEncoded
        )

        check (await node2.historyNetwork.getBlockBody(header)).isOk()

    await node1.stop()
    await node2.stop()

  asyncTest "GetReceipts":
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

    for kind, path in walkDir(testsPath):
      if kind == pcFile and path.splitFile.ext == ".yaml":
        let
          blockData = BlockData.loadFromYaml(path).valueOr:
            raiseAssert "Cannot read test vector: " & error

          headerEncoded = blockData.header.hexToSeqByte()
          receiptsEncoded = blockData.receipts.hexToSeqByte()
          header = decodeRlp(headerEncoded, Header).expect("Valid header")
          contentKey = receiptsContentKey(header.number)

        node1.portalProtocol().storeContent(
          contentKey.encode(), contentKey.toContentId(), receiptsEncoded
        )

        check (await node2.historyNetwork.getReceipts(header)).isOk()

    await node1.stop()
    await node2.stop()
