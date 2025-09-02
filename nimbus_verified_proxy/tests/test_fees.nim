# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [], gcsafe.}

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

suite "test transaction verification":
  test "check api methods":
    let
      ts = TestApiState.init(1.u256)
      vp = startTestSetup(ts, 1, 1, 8777)
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")

    ts.loadBlock(blk)
    check vp.headerStore.add(convHeader(blk), blk.hash).isOk()

    let
      gasPrice = waitFor vp.proxy.getClient().eth_gasPrice()
      priorityFee = waitFor vp.proxy.getClient().eth_maxPriorityFeePerGas()

    # we are only checking the API interface atm
    check:
      gasPrice > Quantity(0)
      priorityFee > Quantity(0)

    try:
      let blobFee = waitFor vp.proxy.getClient().eth_blobBaseFee()
      # blobs weren't enables on paris
      check false
    except CatchableError:
      # TODO: change this to an appropriate error whenever refactoring is done
      check true

    ts.clear()
    vp.headerStore.clear()

    let blk2 = getBlockFromJson("nimbus_verified_proxy/tests/data/Prague.json")

    ts.loadBlock(blk)
    check vp.headerStore.add(convHeader(blk), blk.hash).isOk()

    let blobFeePrague = waitFor vp.proxy.getClient().eth_blobBaseFee()

    check:
      blobFeePrague > Quantity(0)

    vp.stopTestSetup()
