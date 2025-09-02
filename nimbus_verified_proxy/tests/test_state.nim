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
  web3/[eth_api, eth_api_types],
  json_rpc/[rpcclient, rpcserver, rpcproxy],
  stew/byteutils,
  eth/common/[base, eth_types_rlp],
  ../rpc/blocks,
  ../types,
  ../header_store,
  ./test_utils,
  ./test_api_backend

suite "test state verification":
  let
    ts = TestApiState.init(1.u256)
    vp = startTestSetup(ts, 1, 1, 8897)

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

    let 
      addStatus = vp.headerStore.add(convHeader(blk), blk.hash)
      finalizeStatus = vp.headerStore.updateFinalized(convHeader(blk), blk.hash)

    check:
      addStatus.isOk()
      finalizeStatus.isOk()

    let
      verifiedBalance = waitFor vp.proxy.getClient().eth_getBalance(address, latestTag)
      verifiedNonce =
        waitFor vp.proxy.getClient().eth_getTransactionCount(address, latestTag)
      verifiedCode = waitFor vp.proxy.getClient().eth_getCode(address, latestTag)
      verifiedSlot =
        waitFor vp.proxy.getClient().eth_getStorageAt(address, slot, latestTag)
      verifiedCall = waitFor vp.proxy.getClient().eth_call(tx, latestTag)
      verifiedAccessList =
        waitFor vp.proxy.getClient().eth_createAccessList(tx, latestTag)
      verifiedEstimate = waitFor vp.proxy.getClient().eth_estimateGas(tx, latestTag)

    check:
      verifiedBalance == UInt256.fromHex("0x1d663f6a4afc5b01abb5d")
      verifiedNonce == Quantity(1)
      verifiedCode == contractCode
      verifiedSlot.to(UInt256) ==
        UInt256.fromHex(
          "0x000000000000000000000000000000000000000000000000288a82d13c3d1600"
        )
      verifiedCall ==
        "000000000000000000000000000000000000000000000000288a82d13c3d1600".hexToSeqByte()
      verifiedAccessList == accessList
      verifiedEstimate == Quantity(22080)

    ts.clear()
    vp.headerStore.clear()
