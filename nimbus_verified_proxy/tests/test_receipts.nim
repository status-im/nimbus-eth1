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
  chronos,
  web3/[eth_api, eth_api_types],
  eth/common/eth_types_rlp,
  ../engine/blocks,
  ../engine/types,
  ../engine/header_store,
  ./test_utils,
  ./test_api_backend

suite "test receipts verification":
  let
    ts = TestApiState.init(1.u256)
    engine = initTestEngine(ts, 1, 1)

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
    check:
      engine.headerStore.add(convHeader(blk), blk.hash).isOk()
      engine.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

    var verified = waitFor engine.frontend.eth_getBlockReceipts(numberTag)
    check rxs == verified.get()

    verified = waitFor engine.frontend.eth_getBlockReceipts(finalTag)
    check rxs == verified.get()

    verified = waitFor engine.frontend.eth_getBlockReceipts(earliestTag)
    check rxs == verified.get()

    verified = waitFor engine.frontend.eth_getBlockReceipts(latestTag)
    check rxs == verified.get()

    let verifiedReceipt =
      waitFor engine.frontend.eth_getTransactionReceipt(rxs[0].transactionHash)
    check rxs[0] == verifiedReceipt

    ts.clear()
    engine.headerStore.clear()

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
    check:
      engine.headerStore.add(convHeader(blk), blk.hash).isOk()
      engine.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

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
      let verifiedLogs = waitFor engine.frontend.eth_getLogs(filterOptions)
      check verifiedLogs.len == logs.len

    ts.clear()
    engine.headerStore.clear()

  test "create filters and uninstall filters":
    # filter options without any tags would test resolving default "latest"
    let filterOptions = FilterOptions(
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

    let
      # create a filter
      newFilter = waitFor engine.frontend.eth_newFilter(filterOptions)
      # deleting will prove if the filter was created
      delStatus = waitFor engine.frontend.eth_uninstallFilter(newFilter)

    check delStatus

    let
      unknownFilterId = "thisisacorrectfilterid"
      delStatus2 = waitFor engine.frontend.eth_uninstallFilter(newFilter)

    check not delStatus2

  test "get logs using filter changes":
    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      rxs = getReceiptsFromJson("nimbus_verified_proxy/tests/data/receipts.json")
      logs = getLogsFromJson("nimbus_verified_proxy/tests/data/logs.json")

    # update block tags because getLogs (uses)-> getReceipts (uses)-> getHeader
    ts.loadBlockReceipts(blk, rxs)

    check:
      engine.headerStore.add(convHeader(blk), blk.hash).isOk()
      engine.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

    # filter options without any tags would test resolving default "latest"
    let filterOptions = FilterOptions(
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

    let
      # create a filter
      newFilter = waitFor engine.frontend.eth_newFilter(filterOptions)
      filterLogs = waitFor engine.frontend.eth_getFilterLogs(newFilter)
      filterChanges = waitFor engine.frontend.eth_getFilterChanges(newFilter)

    check filterLogs.len == logs.len
    check filterChanges.len == logs.len

    try:
      let againFilterChanges = waitFor engine.frontend.eth_getFilterChanges(newFilter)
      check false
    except CatchableError:
      check true

    ts.clear()
    engine.headerStore.clear()
