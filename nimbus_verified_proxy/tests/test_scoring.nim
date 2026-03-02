# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [].}

import
  unittest2,
  chronos,
  stint,
  web3/[eth_api, eth_api_types],
  eth/common/[base, eth_types_rlp],
  ../engine/blocks,
  ../engine/engine,
  ../engine/header_store,
  ../engine/types,
  ./test_utils,
  ./test_api_backend

let scoringEngineConf = RpcVerificationEngineConf(
  chainId: 1.u256,
  maxBlockWalk: 1,
  headerStoreLen: 16,
  accountCacheLen: 1,
  codeCacheLen: 1,
  storageCacheLen: 1,
  parallelBlockDownloads: 2,
)

suite "backend scoring":
  let
    blk = getBlockFromJson("nimbus_verified_proxy/tests/data/proof_block.json")
    address = address"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    latestTag = BlockTag(kind: BlockIdentifierKind.bidAlias, alias: "latest")

  test "availability penalty on transport failure":
    let ts = TestApiState.init(1.u256)
    var backend = initTestApiBackend(ts)
    backend.eth_getProof = proc(
        address: Address, slots: seq[UInt256], blkNum: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
      return err((BackendFetchError, "simulated transport failure", UNTAGGED))

    let engine = RpcVerificationEngine.init(scoringEngineConf).valueOr:
      raise newException(TestProxyError, error.errMsg)
    engine.registerBackend(backend, fullCapabilities)

    check engine.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

    let res = waitFor engine.frontend.eth_getBalance(address, latestTag)

    check:
      res.isErr()
      engine.scores[0].availability < 0
      engine.scores[0].quality == 0

  test "quality penalty on verification failure":
    let ts = TestApiState.init(1.u256)
    var backend = initTestApiBackend(ts)
    backend.eth_getProof = proc(
        address: Address, slots: seq[UInt256], blkNum: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
      # Return a bogus accountProof node so verifyMptProof returns InvalidProof.
      # The node's hash won't match the block's stateRoot, triggering VerificationError.
      return ok(
        ProofResponse(
          address: address,
          accountProof: @[RlpEncodedBytes(@[0x01u8])],
          balance: 0.u256,
          nonce: 0.Quantity,
          codeHash: default(Hash32),
          storageHash: default(Hash32),
          storageProof: @[],
        )
      )

    let engine = RpcVerificationEngine.init(scoringEngineConf).valueOr:
      raise newException(TestProxyError, error.errMsg)
    engine.registerBackend(backend, fullCapabilities)

    check engine.headerStore.updateFinalized(convHeader(blk), blk.hash).isOk()

    let res = waitFor engine.frontend.eth_getBalance(address, latestTag)

    check:
      res.isErr()
      engine.scores[0].quality < 0
      engine.scores[0].availability == 1

  test "ineligible backend not selected":
    let ts = TestApiState.init(1.u256)
    let engine = RpcVerificationEngine.init(scoringEngineConf).valueOr:
      raise newException(TestProxyError, error.errMsg)
    engine.registerBackend(initTestApiBackend(ts), fullCapabilities)

    engine.scores[0].quality = -10

    check engine.backendFor(GetProof).isErr()

  test "excluded backend recovers after enough requests":
    let ts = TestApiState.init(1.u256)
    let engine = RpcVerificationEngine.init(scoringEngineConf).valueOr:
      raise newException(TestProxyError, error.errMsg)
    engine.registerBackend(initTestApiBackend(ts), fullCapabilities)

    engine.scores[0].quality = -4

    for _ in 0 ..< 3:
      check engine.backendFor(GetProof).isErr()

    check engine.backendFor(GetProof).isOk()
