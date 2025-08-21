# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [].}

import
  unittest2,
  web3/[eth_api, eth_api_types],
  json_rpc/[rpcclient, rpcserver, rpcproxy],
  eth/common/eth_types_rlp,
  ../rpc/blocks,
  ../types,
  ../header_store,
  ./test_utils,
  ./test_api_backend

suite "test receipts verification":
  let
    ts = TestApiState.init(1.u256)
    vp = startTestSetup(ts, 1, 1, 8887)

  test "get receipts using block tags":
    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      rxs = getReceiptsFromJson("nimbus_verified_proxy/tests/data/receipts.json")
      numberTag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: blk.number)
      finalTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "finalized")
      earliestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "earliest")
      latestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "latest")

    ts.loadBlockReceipts(blk, rxs)
    ts.loadReceipt(rxs[0].transactionHash, rxs[0])
    discard vp.headerStore.add(convHeader(blk), blk.hash)
    discard vp.headerStore.updateFinalized(convHeader(blk), blk.hash)

    var verified = waitFor vp.proxy.getClient().eth_getBlockReceipts(numberTag)
    check rxs == verified.get()

    verified = waitFor vp.proxy.getClient().eth_getBlockReceipts(finalTag)
    check rxs == verified.get()

    verified = waitFor vp.proxy.getClient().eth_getBlockReceipts(earliestTag)
    check rxs == verified.get()

    verified = waitFor vp.proxy.getClient().eth_getBlockReceipts(latestTag)
    check rxs == verified.get()

    let verifiedReceipt =
      waitFor vp.proxy.getClient().eth_getTransactionReceipt(rxs[0].transactionHash)
    check rxs[0] == verifiedReceipt

    ts.clear()
    vp.headerStore.clear()

  test "get logs using tags":
    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      rxs = getReceiptsFromJson("nimbus_verified_proxy/tests/data/receipts.json")
      logs = getLogsFromJson("nimbus_verified_proxy/tests/data/logs.json")
      numberTag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: blk.number)
      finalTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "finalized")
      earliestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "earliest")
      latestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "latest")
      tags = [numberTag, finalTag, earliestTag, latestTag]

    # update block tags because getLogs (uses)-> getReceipts (uses)-> getHeader
    ts.loadBlockReceipts(blk, rxs)
    discard vp.headerStore.add(convHeader(blk), blk.hash)
    discard vp.headerStore.updateFinalized(convHeader(blk), blk.hash)

    for tag in tags:
      let filterOptions = FilterOptions(
        fromBlock: Opt.some(tag),
        toBlock: Opt.some(tag),
          # same tag because we load only one block into the backend
        topics:
          @[
            TopicOrList(
              kind: SingleOrListKind.slkSingle,
              single:
                bytes32"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
            )
          ],
        blockHash: Opt.none(Hash32),
      )

      ts.loadLogs(filterOptions, logs)
      let verifiedLogs = waitFor vp.proxy.getClient().eth_getLogs(filterOptions)
      check verifiedLogs.len == logs.len
