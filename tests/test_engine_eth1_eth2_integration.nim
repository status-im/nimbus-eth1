# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  chronos,
  unittest2,
  ../execution_chain/conf,
  ../execution_chain/common,
  ../execution_chain/core/chain,
  ../execution_chain/core/tx_pool,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/beacon/beacon_engine,
  ../execution_chain/rpc/engine_rest_api

import beacon_chain/spec/datatypes/electra
import beacon_chain/el/engine_rest_conversions

func digestOf(h: Hash32): Digest =
  Digest(data: h.data)

proc setupBeaconEngine(network: string): BeaconEngineRef =
  let config = makeConfig(@[
    "--network:" & network,
    "--listen-address: 127.0.0.1",
  ])
  let com = CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    config.computeNetworkParams())
  let chain = ForkedChainRef.init(com, enableQueue = true)
  BeaconEngineRef.new(TxPoolRef.new(chain))

suite "Engine REST API: nimbus-eth1 server and nimbus-eth2 client wire compatibility":
  let ben = setupBeaconEngine("tests/customgenesis/engine_api_genesis_prague.json")
  let restServer = initEngineRestServer(
    ben, initTAddress("127.0.0.1:0")).valueOr:
    raiseAssert "failed to start REST server: " & error
  restServer.start()
  let base = "http://" & $restServer.localAddress()
  let client = RestClientRef.new(base).valueOr:
    raiseAssert "failed to create nimbus-eth2 REST client: " & $error
  let genesisDigest = digestOf(ben.com.genesisHeader.computeBlockHash)

  var payloadId: Bytes8
  var builtPayload: electra.ExecutionPayloadForSigning

  suiteTeardown:
    waitFor client.closeWait()
    waitFor restServer.closeWait()
    waitFor ben.chain.stopProcessingQueue()

  test "eth2 client forkchoiceUpdated (with attributes) builds a payload on the eth1 server":
    let resp = waitFor client.postForkchoice(EngineFork.Cancun, ForkchoiceUpdateCancun(
      forkchoice_state: ForkchoiceState(
        head_block_hash: genesisDigest,
        safe_block_hash: genesisDigest,
        finalized_block_hash: genesisDigest),
      payload_attributes: optSome(PayloadAttributesCancun(
        timestamp: uint64(ben.com.genesisHeader.timestamp) + 1))))
    check resp.status == 200
    let status = decodeSszResponse(ForkchoiceUpdateResponse, resp).asConsensusType
    check status.payloadStatus.status == PayloadStatusCode.VALID
    check status.payloadId.isSome
    payloadId = status.payloadId.get

  test "eth2 client getPayload fetches the eth1-built payload, decoded via eth2's own conversions":
    let resp = waitFor client.getPayload(EngineFork.Prague, payloadId.to0xHex())
    check resp.status == 200
    builtPayload = decodeSszResponse(BuiltPayloadPrague, resp).asConsensusType
    check builtPayload.executionPayload.block_number == 1'u64
    check builtPayload.executionPayload.parent_hash == genesisDigest

  test "eth2 client newPayload submits the eth2-decoded payload back to the eth1 server as VALID":
    let resp = waitFor client.postPayload(EngineFork.Prague,
      builtPayload.executionPayload.asSszEnvelopePrague(
        default(Digest), builtPayload.executionRequests))
    check resp.status == 200
    let status = decodeSszResponse(PayloadStatus, resp).asConsensusType
    check status.status == PayloadStatusCode.VALID

  test "eth2 client forkchoiceUpdated finalizes the newly submitted block":
    let blockHash = builtPayload.executionPayload.block_hash
    let resp = waitFor client.postForkchoice(EngineFork.Cancun, ForkchoiceUpdateCancun(
      forkchoice_state: ForkchoiceState(
        head_block_hash: blockHash,
        safe_block_hash: blockHash,
        finalized_block_hash: blockHash)))
    check resp.status == 200
    let status = decodeSszResponse(ForkchoiceUpdateResponse, resp).asConsensusType
    check status.payloadStatus.status == PayloadStatusCode.VALID
