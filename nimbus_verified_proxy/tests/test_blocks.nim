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

proc checkCompleteness(vp: VerifiedRpcProxy, ts: TestApiState, blockName: string) =
  let blk = getBlockFromJson("nimbus_verified_proxy/tests/data/" & blockName & ".json")

  ts.loadFullBlock(blk.hash, blk)
  let status = vp.headerStore.add(convHeader(blk), blk.hash).valueOr:
    raise newException(ValueError, error)

  # reuse verified proxy's internal client. Conveniently it is looped back to the proxy server
  let verifiedBlk = waitFor vp.proxy.getClient().eth_getBlockByHash(blk.hash, true)

  let
    blkStr = JrpcConv.encode(blk).JsonString
    verifiedBlkStr = JrpcConv.encode(verifiedBlk).JsonString

  check blkStr == verifiedBlkStr

suite "test verified blocks":
  test "completeness check for every fork":
    let
      ts = TestApiState.init(1.u256)
      vp = startTestSetup(ts, 1, 1)
      forkBlockNames = [
        "Frontier", "Homestead", "DAO", "TangerineWhistle", "SpuriousDragon",
        "Byzantium", "Constantinople", "Istanbul", "MuirGlacier", "StakingDeposit",
        "Berlin", "London", "ArrowGlacier", "GrayGlacier", "Paris", "Shanghai",
        "Cancun", "Prague",
      ]

    for blockName in forkBlockNames:
      checkCompleteness(vp, ts, blockName)
      ts.clear()
      vp.headerStore.clear()
