# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [].}

import
  unittest2,
  chronos,
  web3/[eth_api_types, eth_api],
  ../engine/header_store,
  ../engine/blocks,
  ../engine/types,
  ./test_utils,
  ./test_api_backend

suite "test verified blocks":
  let
    ts = TestApiState.init(1.u256)
    (engine, frontend) = initTestEngine(ts, 1, 9).valueOr:
      raise newException(TestProxyError, error.errMsg)

  test "check fetching blocks on every fork":
    let forkBlockNames = [
      "Frontier", "Homestead", "DAO", "TangerineWhistle", "SpuriousDragon", "Byzantium",
      "Constantinople", "Istanbul", "MuirGlacier", "StakingDeposit", "Berlin", "London",
      "ArrowGlacier", "GrayGlacier", "Paris", "Shanghai", "Cancun", "Prague",
    ]

    for blockName in forkBlockNames:
      let blk =
        getBlockFromJson("nimbus_verified_proxy/tests/data/" & blockName & ".json")

      ts.loadBlock(blk)
      check engine.headerStore.add(convHeader(blk), blk.hash).isOk()

      let verifiedBlk = waitFor frontend.eth_getBlockByHash(blk.hash, true)

      check:
        verifiedBlk.isOk()
        blk == verifiedBlk.get()

      ts.clear()
      engine.headerStore.clear()

  test "check fetching blocks by number and tags":
    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      numberTag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: blk.number)
      finalTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "finalized")
      earliestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "earliest")
      latestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "latest")
      hash = blk.hash

    ts.clear()
    engine.headerStore.clear()

    ts.loadBlock(blk)
    check:
      engine.headerStore.add(convHeader(blk), blk.hash).isOk()
      engine.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

    var verifiedBlk = waitFor frontend.eth_getBlockByNumber(numberTag, true)
    check:
      verifiedBlk.isOk()
      blk == verifiedBlk.get()

    verifiedBlk = waitFor frontend.eth_getBlockByNumber(finalTag, true)
    check:
      verifiedBlk.isOk()
      blk == verifiedBlk.get()

    verifiedBlk = waitFor frontend.eth_getBlockByNumber(earliestTag, true)
    check:
      verifiedBlk.isOk()
      blk == verifiedBlk.get()

    verifiedBlk = waitFor frontend.eth_getBlockByNumber(latestTag, true)
    check:
      verifiedBlk.isOk()
      blk == verifiedBlk.get()

  test "check block walk":
    ts.clear()
    engine.headerStore.clear()

    let
      targetBlockNum = 22431080
      sourceBlockNum = 22431090

    for i in targetBlockNum .. sourceBlockNum:
      let
        filename = "nimbus_verified_proxy/tests/data/" & $i & ".json"
        blk = getBlockFromJson(filename)

      ts.loadBlock(blk)
      if i == sourceBlockNum:
        check engine.headerStore.add(convHeader(blk), blk.hash).isOk()
        check engine.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

    let
      unreachableTargetTag =
        BlockTag(kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum))
      reachableTargetTag = BlockTag(
        kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum + 1)
      )

    let verifiedBlkUnreachable =
      waitFor frontend.eth_getBlockByNumber(unreachableTargetTag, true)

    check:
      verifiedBlkUnreachable.isErr()
      verifiedBlkUnreachable.error.errType == FrontendError

    let verifiedBlkReachable =
      waitFor frontend.eth_getBlockByNumber(reachableTargetTag, true)

    check:
      verifiedBlkReachable.isOk()

  test "check block related API methods":
    ts.clear()
    engine.headerStore.clear()

    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      numberTag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: blk.number)
      hash = blk.hash

    ts.loadBlock(blk)
    check engine.headerStore.add(convHeader(blk), blk.hash).isOk()

    let
      uncleCountByHash = waitFor frontend.eth_getUncleCountByBlockHash(hash)
      uncleCountByNum = waitFor frontend.eth_getUncleCountByBlockNumber(numberTag)
      txCountByHash = waitFor frontend.eth_getBlockTransactionCountByHash(hash)
      txCountByNum = waitFor frontend.eth_getBlockTransactionCountByNumber(numberTag)
      txByHash =
        waitFor frontend.eth_getTransactionByBlockHashAndIndex(hash, Quantity(0))
      txByNum =
        waitFor frontend.eth_getTransactionByBlockNumberAndIndex(numberTag, Quantity(0))

    check:
      uncleCountByHash.isOk()
      uncleCountByNum.isOk()
      txCountByHash.isOk()
      txCountByNum.isOk()
      Quantity(blk.uncles.len()) == uncleCountByHash.get()
      uncleCountByHash.get() == uncleCountByNum.get()
      Quantity(blk.transactions.len()) == txCountByHash.get()
      txCountByHash.get() == txCountByNum.get()

    doAssert blk.transactions[0].kind == tohTx

    check:
      txByHash.isOk()
      txByNum.isOk()
      txByHash.get() == blk.transactions[0].tx
      txByHash.get() == txByNum.get()
