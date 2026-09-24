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
  ssz_serialization,
  web3/[engine_api_types, primitives],
  ../execution_chain/conf,
  ../execution_chain/common,
  ../execution_chain/core/chain,
  ../execution_chain/core/tx_pool,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/beacon/beacon_engine,
  ../execution_chain/rpc/engine_rest_api

import beacon_chain/el/engine_rest_client
from beacon_chain/spec/engine_authentication import nil

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
  let client = EngineRestClient.new(
    base, Opt.none(engine_authentication.JwtSharedKey))
  let genesisHash = ben.com.genesisHeader.computeBlockHash

  var payloadId: Bytes8
  var builtPayload: GetPayloadV4Response

  suiteTeardown:
    waitFor client.close()
    waitFor restServer.closeWait()
    waitFor ben.chain.stopProcessingQueue()

  test "eth2 client forkchoiceUpdated (with attributes) builds a payload on the eth1 server":
    let resp = waitFor client.forkchoiceUpdated(
      ForkchoiceStateV1(
        headBlockHash: genesisHash,
        safeBlockHash: genesisHash,
        finalizedBlockHash: genesisHash),
      Opt.some(PayloadAttributesV3(
        timestamp: Quantity(uint64(ben.com.genesisHeader.timestamp) + 1),
        prevRandao: default(Bytes32),
        suggestedFeeRecipient: default(Address),
        withdrawals: @[],
        parentBeaconBlockRoot: default(Hash32))),
      EngineFork.Prague)
    check resp.payloadStatus.status == PayloadExecutionStatus.valid
    check resp.payloadId.isSome
    payloadId = resp.payloadId.get

  test "eth2 client getPayload fetches the eth1-built payload, decoded via eth2's own conversions":
    builtPayload = waitFor client.getPayload(GetPayloadV4Response, payloadId)
    check builtPayload.executionPayload.blockNumber == Quantity(1'u64)
    check builtPayload.executionPayload.parentHash == genesisHash

  test "eth2 client newPayload submits the eth2-decoded payload back to the eth1 server as VALID":
    let status = waitFor client.newPayload(
      EngineFork.Prague, builtPayload.executionPayload,
      default(Hash32), builtPayload.executionRequests)
    check status.status == PayloadExecutionStatus.valid

  test "eth2 client forkchoiceUpdated finalizes the newly submitted block":
    let blockHash = builtPayload.executionPayload.blockHash
    let resp = waitFor client.forkchoiceUpdated(
      ForkchoiceStateV1(
        headBlockHash: blockHash,
        safeBlockHash: blockHash,
        finalizedBlockHash: blockHash),
      Opt.none(PayloadAttributesV3),
      EngineFork.Prague)
    check resp.payloadStatus.status == PayloadExecutionStatus.valid
