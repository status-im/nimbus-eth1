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
  web3/[eth_api_types, eth_api],
  ../engine/header_store,
  ../engine/blocks,
  ../engine/types,
  ./test_utils,
  ./test_api_backend

suite "test verified blocks":
  let
    ts = TestApiState.init(1.u256)
    engine = initTestEngine(ts, 1, 9) # header store holds 1 and maxBlockWalk is 9

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

      let verifiedBlk = waitFor engine.frontend.eth_getBlockByHash(blk.hash, true)

      check blk == verifiedBlk

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

    var verifiedBlk = waitFor engine.frontend.eth_getBlockByNumber(numberTag, true)
    check blk == verifiedBlk

    verifiedBlk = waitFor engine.frontend.eth_getBlockByNumber(finalTag, true)
    check blk == verifiedBlk

    verifiedBlk = waitFor engine.frontend.eth_getBlockByNumber(earliestTag, true)
    check blk == verifiedBlk

    verifiedBlk = waitFor engine.frontend.eth_getBlockByNumber(latestTag, true)
    check blk == verifiedBlk

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

    let
      unreachableTargetTag =
        BlockTag(kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum))
      reachableTargetTag = BlockTag(
        kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum + 1)
      )

    # TODO: catch the exact error 
    try:
      let verifiedBlk =
        waitFor engine.frontend.eth_getBlockByNumber(unreachableTargetTag, true)
      check(false)
    except CatchableError as e:
      check(true)

    # TODO: catch the exact error 
    try:
      let verifiedBlk =
        waitFor engine.frontend.eth_getBlockByNumber(reachableTargetTag, true)
      check(true)
    except CatchableError as e:
      check(false)

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
      uncleCountByHash = waitFor engine.frontend.eth_getUncleCountByBlockHash(hash)
      uncleCountByNum =
        waitFor engine.frontend.eth_getUncleCountByBlockNumber(numberTag)
      txCountByHash =
        waitFor engine.frontend.eth_getBlockTransactionCountByHash(hash)
      txCountByNum =
        waitFor engine.frontend.eth_getBlockTransactionCountByNumber(numberTag)
      txByHash = waitFor engine.frontend.eth_getTransactionByBlockHashAndIndex(
        hash, Quantity(0)
      )
      txByNum = waitFor engine.frontend.eth_getTransactionByBlockNumberAndIndex(
        numberTag, Quantity(0)
      )

    check Quantity(blk.uncles.len()) == uncleCountByHash
    check uncleCountByHash == uncleCountByNum
    check Quantity(blk.transactions.len()) == txCountByHash
    check txCountByHash == txCountByNum

    doAssert blk.transactions[0].kind == tohTx

    check txByHash == blk.transactions[0].tx
    check txByHash == txByNum
