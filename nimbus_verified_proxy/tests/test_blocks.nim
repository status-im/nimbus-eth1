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
  json_rpc/[rpcclient, rpcserver, rpcproxy],
  web3/[eth_api_types, eth_api],
  ../header_store,
  ../rpc/blocks,
  ../types,
  ./test_utils,
  ./test_api_backend

suite "test verified blocks":
  let
    ts = TestApiState.init(1.u256)
    vp = startTestSetup(ts, 1, 9) # header store holds 1 and maxBlockWalk is 9

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
      check vp.headerStore.add(convHeader(blk), blk.hash).isOk()

      let verifiedBlk = waitFor vp.frontend.eth_getBlockByHash(blk.hash, true)

      check blk == verifiedBlk

      ts.clear()
      vp.headerStore.clear()

  test "check fetching blocks by number and tags":
    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      numberTag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: blk.number)
      finalTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "finalized")
      earliestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "earliest")
      latestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "latest")
      hash = blk.hash

    ts.clear()
    vp.headerStore.clear()

    ts.loadBlock(blk)
    check:
      vp.headerStore.add(convHeader(blk), blk.hash).isOk()
      vp.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

    var verifiedBlk = waitFor vp.frontend.eth_getBlockByNumber(numberTag, true)
    check blk == verifiedBlk

    verifiedBlk = waitFor vp.frontend.eth_getBlockByNumber(finalTag, true)
    check blk == verifiedBlk

    verifiedBlk = waitFor vp.frontend.eth_getBlockByNumber(earliestTag, true)
    check blk == verifiedBlk

    verifiedBlk = waitFor vp.frontend.eth_getBlockByNumber(latestTag, true)
    check blk == verifiedBlk

  test "check block walk":
    ts.clear()
    vp.headerStore.clear()

    let
      targetBlockNum = 22431080
      sourceBlockNum = 22431090

    for i in targetBlockNum .. sourceBlockNum:
      let
        filename = "nimbus_verified_proxy/tests/data/" & $i & ".json"
        blk = getBlockFromJson(filename)

      ts.loadBlock(blk)
      if i == sourceBlockNum:
        check vp.headerStore.add(convHeader(blk), blk.hash).isOk()

    let
      unreachableTargetTag =
        BlockTag(kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum))
      reachableTargetTag = BlockTag(
        kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum + 1)
      )

    # TODO: catch the exact error 
    try:
      let verifiedBlk =
        waitFor vp.frontend.eth_getBlockByNumber(unreachableTargetTag, true)
      check(false)
    except CatchableError as e:
      check(true)

    # TODO: catch the exact error 
    try:
      let verifiedBlk =
        waitFor vp.frontend.eth_getBlockByNumber(reachableTargetTag, true)
      check(true)
    except CatchableError as e:
      check(false)

  test "check block related API methods":
    ts.clear()
    vp.headerStore.clear()

    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      numberTag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: blk.number)
      hash = blk.hash

    ts.loadBlock(blk)
    check vp.headerStore.add(convHeader(blk), blk.hash).isOk()

    let
      uncleCountByHash = waitFor vp.frontend.eth_getUncleCountByBlockHash(hash)
      uncleCountByNum =
        waitFor vp.frontend.eth_getUncleCountByBlockNumber(numberTag)
      txCountByHash =
        waitFor vp.frontend.eth_getBlockTransactionCountByHash(hash)
      txCountByNum =
        waitFor vp.frontend.eth_getBlockTransactionCountByNumber(numberTag)
      txByHash = waitFor vp.frontend.eth_getTransactionByBlockHashAndIndex(
        hash, Quantity(0)
      )
      txByNum = waitFor vp.frontend.eth_getTransactionByBlockNumberAndIndex(
        numberTag, Quantity(0)
      )

    check Quantity(blk.uncles.len()) == uncleCountByHash
    check uncleCountByHash == uncleCountByNum
    check Quantity(blk.transactions.len()) == txCountByHash
    check txCountByHash == txCountByNum

    doAssert blk.transactions[0].kind == tohTx

    check txByHash == blk.transactions[0].tx
    check txByHash == txByNum

    vp.stopTestSetup()
