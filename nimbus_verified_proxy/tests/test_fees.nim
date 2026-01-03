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
  chronos,
  web3/[eth_api, eth_api_types],
  eth/common/eth_types_rlp,
  ../engine/blocks,
  ../engine/types,
  ../engine/header_store,
  ./test_utils,
  ./test_api_backend

suite "test fees verification":
  test "check api methods":
    let
      ts = TestApiState.init(1.u256)
      engine = initTestEngine(ts, 1, 1).valueOr:
        raise newException(TestProxyError, error.errMsg)
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/Paris.json")

    ts.loadBlock(blk)
    check engine.headerStore.add(convHeader(blk), blk.hash).isOk()

    let
      gasPrice = waitFor engine.frontend.eth_gasPrice()
      priorityFee = waitFor engine.frontend.eth_maxPriorityFeePerGas()

    # we are only checking the API interface atm
    check:
      gasPrice.isOk()
      priorityFee.isOk()
      gasPrice.get() > Quantity(0)
      priorityFee.get() > Quantity(0)

    let blobFee = waitFor engine.frontend.eth_blobBaseFee()

    # blobs weren't enabled on paris
    check blobFee.isErr()

    ts.clear()
    engine.headerStore.clear()

    let blk2 = getBlockFromJson("nimbus_verified_proxy/tests/data/Prague.json")

    ts.loadBlock(blk2)
    check engine.headerStore.add(convHeader(blk2), blk2.hash).isOk()

    let blobFeePrague = waitFor engine.frontend.eth_blobBaseFee()

    check:
      blobFeePrague.isOk()
      blobFeePrague.get() > u256(0)

    ts.clear()
    engine.headerStore.clear()
