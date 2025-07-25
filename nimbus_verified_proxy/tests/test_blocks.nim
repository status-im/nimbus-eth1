# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  stew/io2,
  json_rpc/[rpcclient, rpcserver, rpcproxy, jsonmarshal],
  web3/[eth_api_types, eth_api],
  ../header_store,
  ../rpc/blocks,
  ../types,
  ./test_setup,
  ./test_api_backend

proc getBlockFromJson(filepath: string): BlockObject =
  var blkBytes = readAllBytes(filepath)
  let blk = JrpcConv.decode(blkBytes.get, BlockObject)
  return blk

# TODO: define the == operator instead
template checkEqual(blk1: BlockObject, blk2: BlockObject): bool =
  JrpcConv.encode(blk1).JsonString == JrpcConv.encode(blk2).JsonString

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
      discard vp.headerStore.add(convHeader(blk), blk.hash)

      # reuse verified proxy's internal client. Conveniently it is looped back to the proxy server
      let verifiedBlk = waitFor vp.proxy.getClient().eth_getBlockByHash(blk.hash, true)

      check checkEqual(blk, verifiedBlk)

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
    discard vp.headerStore.add(convHeader(blk), blk.hash)
    discard vp.headerStore.updateFinalized(convHeader(blk), blk.hash)

    var verifiedBlk = waitFor vp.proxy.getClient().eth_getBlockByNumber(numberTag, true)
    check checkEqual(blk, verifiedBlk)

    verifiedBlk = waitFor vp.proxy.getClient().eth_getBlockByNumber(finalTag, true)
    check checkEqual(blk, verifiedBlk)

    verifiedBlk = waitFor vp.proxy.getClient().eth_getBlockByNumber(earliestTag, true)
    check checkEqual(blk, verifiedBlk)

    verifiedBlk = waitFor vp.proxy.getClient().eth_getBlockByNumber(latestTag, true)
    check checkEqual(blk, verifiedBlk)

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
        discard vp.headerStore.add(convHeader(blk), blk.hash)

    let
      unreachableTargetTag =
        BlockTag(kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum))
      reachableTargetTag = BlockTag(
        kind: BlockIdentifierKind.bidNumber, number: Quantity(targetBlockNum + 1)
      )

    # TODO: catch the exact error by comparing error strings 
    try:
      let verifiedBlk =
        waitFor vp.proxy.getClient().eth_getBlockByNumber(unreachableTargetTag, true)
      check(false)
    except CatchableError as e:
      echo e.msg
      check(true)

    # TODO: catch the exact error by comparing error strings 
    try:
      let verifiedBlk =
        waitFor vp.proxy.getClient().eth_getBlockByNumber(reachableTargetTag, true)
      check(true)
    except CatchableError as e:
      echo e.msg
      check(false)

  test "check block related API methods":
    ts.clear()
    vp.headerStore.clear()

    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")
      numberTag = BlockTag(kind: BlockIdentifierKind.bidNumber, number: blk.number)
      hash = blk.hash

    ts.loadBlock(blk)
    discard vp.headerStore.add(convHeader(blk), blk.hash)

    let
      uncleCountByHash = waitFor vp.proxy.getClient().eth_getUncleCountByBlockHash(hash)
      uncleCountByNum =
        waitFor vp.proxy.getClient().eth_getUncleCountByBlockNumber(numberTag)
      txCountByHash =
        waitFor vp.proxy.getClient().eth_getBlockTransactionCountByHash(hash)
      txCountByNum =
        waitFor vp.proxy.getClient().eth_getBlockTransactionCountByNumber(numberTag)
      txByHash = waitFor vp.proxy.getClient().eth_getTransactionByBlockHashAndIndex(
        hash, Quantity(0)
      )
      txByNum = waitFor vp.proxy.getClient().eth_getTransactionByBlockNumberAndIndex(
        numberTag, Quantity(0)
      )

    check Quantity(blk.uncles.len()) == uncleCountByHash
    check uncleCountByHash == uncleCountByNum
    check Quantity(blk.transactions.len()) == txCountByHash
    check txCountByHash == txCountByNum

    doAssert blk.transactions[0].kind == tohTx

    check blk.transactions[0].tx == txByHash
    check txByHash == txByNum
