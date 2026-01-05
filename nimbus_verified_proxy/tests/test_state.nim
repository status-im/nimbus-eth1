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
  web3/[eth_api, eth_api_types],
  stew/byteutils,
  eth/common/[base, eth_types_rlp],
  ../engine/blocks,
  ../engine/types,
  ../engine/header_store,
  ./test_utils,
  ./test_api_backend

suite "test state verification":
  let
    ts = TestApiState.init(1.u256)
    engine = initTestEngine(ts, 1, 1).valueOr:
      raise newException(TestProxyError, error.errMsg)

  test "test EVM-based methods":
    let
      blk = getBlockFromJson("nimbus_verified_proxy/tests/data/proof_block.json")
      proof = getProofFromJson("nimbus_verified_proxy/tests/data/storage_proof.json")
      accessList =
        getAccessListFromJson("nimbus_verified_proxy/tests/data/access_list.json")
      contractCode = getCodeFromJson("nimbus_verified_proxy/tests/data/code.json")

      address = address"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
      slot = UInt256.fromHex(
        "0x4de9be9d9a5197eea999984bec8d41aac923403f95449eaf16641fbc3a942711"
      )

      tx = TransactionArgs(
        to: Opt.some(address),
        input: Opt.some(
          "0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4".hexToSeqByte()
        ),
      )

      latestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "latest")

    # load proof also loads the block
    ts.loadProof(address, @[slot], blk, proof)
    # upload the same proof to resolve for accounts
    ts.loadProof(address, @[], blk, proof)
    ts.loadCode(address, blk, contractCode)
    # this is for optimistic state fetch
    ts.loadAccessList(tx, blk, accessList)

    check:
      engine.headerStore.add(convHeader(blk), blk.hash).isOk()
      engine.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

    let
      verifiedBalance = waitFor engine.frontend.eth_getBalance(address, latestTag)
      verifiedNonce =
        waitFor engine.frontend.eth_getTransactionCount(address, latestTag)
      verifiedCode = waitFor engine.frontend.eth_getCode(address, latestTag)
      verifiedSlot = waitFor engine.frontend.eth_getStorageAt(address, slot, latestTag)
      verifiedCall = waitFor engine.frontend.eth_call(tx, latestTag)
      verifiedAccessList = waitFor engine.frontend.eth_createAccessList(tx, latestTag)
      verifiedEstimate = waitFor engine.frontend.eth_estimateGas(tx, latestTag)

    check:
      verifiedBalance.isOk()
      verifiedNonce.isOk()
      verifiedCode.isOk()
      verifiedSlot.isOk()
      verifiedCall.isOk()
      verifiedAccessList.isOk()
      verifiedEstimate.isOk()
      verifiedBalance.get() == UInt256.fromHex("0x1d663f6a4afc5b01abb5d")
      verifiedNonce.get() == Quantity(1)
      verifiedCode.get() == contractCode
      verifiedSlot.get().to(UInt256) ==
        UInt256.fromHex(
          "0x000000000000000000000000000000000000000000000000288a82d13c3d1600"
        )
      verifiedCall.get() ==
        "000000000000000000000000000000000000000000000000288a82d13c3d1600".hexToSeqByte()
      verifiedAccessList.get() == accessList
      verifiedEstimate.get() == Quantity(22080)

    ts.clear()
    engine.headerStore.clear()
