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
      engine.setAnchor(convHeader(blk), blk.hash, Optimistic)

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
    engine.setAnchor(convHeader(blk), blk.hash, Optimistic)
    engine.setAnchor(convHeader(blk), blk.hash, Finalized)

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

  test "blocks below the anchor are walked when no archive backend is configured":
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
        engine.setAnchor(convHeader(blk), blk.hash, Optimistic)
        engine.setAnchor(convHeader(blk), blk.hash, Finalized)

    # the walk reaches at most maxBlockWalk blocks below the anchor
    for i in targetBlockNum + 1 ..< sourceBlockNum:
      let
        blk = getBlockFromJson("nimbus_verified_proxy/tests/data/" & $i & ".json")
        tag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: Quantity(i))
        verifiedBlk = waitFor frontend.eth_getBlockByNumber(tag, true)

      check:
        verifiedBlk.isOk()
        blk == verifiedBlk.get()

    let
      farTag =
        BlockTag(kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum))
      farBlk = waitFor frontend.eth_getBlockByNumber(farTag, true)

    check:
      farBlk.isErr()
      farBlk.error.errType == FrontendError

  test "blocks below the anchor need an EIP-2935 proof with an archive backend":
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
        engine.setAnchor(convHeader(blk), blk.hash, Optimistic)
        engine.setAnchor(convHeader(blk), blk.hash, Finalized)

    # with an archive backend the walk is skipped in favour of EIP-2935, which
    # is not active on the test fixtures
    engine.state = EngineState(archive: true)
    defer:
      engine.state = EngineState(archive: false)

    for i in targetBlockNum ..< sourceBlockNum:
      let
        tag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: Quantity(i))
        verifiedBlk = waitFor frontend.eth_getBlockByNumber(tag, true)

      check:
        verifiedBlk.isErr()
        verifiedBlk.error.errType == UnavailableDataError

  test "check block related API methods":
    ts.clear()
    engine.headerStore.clear()

    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      numberTag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: blk.number)
      hash = blk.hash

    ts.loadBlock(blk)
    engine.setAnchor(convHeader(blk), blk.hash, Optimistic)

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
