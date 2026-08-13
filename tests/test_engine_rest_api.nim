# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[times, typetraits, json],
  chronos,
  chronos/apps/http/httpclient,
  nimcrypto/hmac,
  nimcrypto/sha2,
  stew/base64,
  stew/byteutils,
  unittest2,
  ../execution_chain/conf,
  ../execution_chain/common,
  ../execution_chain/core/chain,
  ../execution_chain/core/tx_pool,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/beacon/beacon_engine,
  ../execution_chain/rpc/engine_ssz_types,
  ../execution_chain/rpc/rpc_server,
  ../execution_chain/rpc/engine_rest_api

func digestOf(h: Hash32): Digest =
  Digest(data: h.data)

func fakeDigest(fill: byte): Digest =
  var d: Digest
  d.data[0] = fill
  d

proc makeToken(key: JwtSharedKey, iat: int64): string =
  let
    headerB64 = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
    payloadJson = "{\"iat\":" & $iat & "}"
    payloadB64 = Base64Url.encode(payloadJson.toOpenArrayByte(0, payloadJson.len - 1))
    signingInput = headerB64 & "." & payloadB64
    sig = Base64Url.encode(sha256.hmac(distinctBase(key), signingInput).data)
  signingInput & "." & sig

proc setupBeaconEngine(): BeaconEngineRef =
  let config = makeConfig(@[
    "--network:tests/customgenesis/engine_api_genesis.json",
    "--listen-address: 127.0.0.1",
  ])
  let com = CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    config.computeNetworkParams())
  let chain = ForkedChainRef.init(com, enableQueue = true)
  BeaconEngineRef.new(TxPoolRef.new(chain))

proc fetchFull(request: HttpClientRequestRef):
    tuple[status: int, contentType: string, data: seq[byte]] =
  # `.fetch()` only surfaces (status, data) -- this pulls the Content-Type
  # header in too, for tests that need to assert on it (e.g. the JSON vs.
  # SSZ split from the spec's Content-Type/Accept matrix).
  let response = waitFor request.send()
  result.status = response.status
  result.contentType = response.headers.getString("Content-Type")
  result.data = waitFor response.getBodyBytes()
  waitFor response.closeWait()

suite "Engine SSZ API REST transport: business logic":
  let ben = setupBeaconEngine()
  let restServer = initEngineRestServer(
    ben, initTAddress("127.0.0.1:0")).valueOr:
    raiseAssert "failed to start REST server: " & error
  restServer.start()
  let base = "http://" & $restServer.localAddress()
  let session = HttpSessionRef.new()
  let genesisDigest = digestOf(ben.com.genesisHeader.computeBlockHash)

  var payloadId: Bytes8
  var payloadIdHex: string
  var builtPayload: ExecutionPayloadParis

  suiteTeardown:
    waitFor session.closeWait()
    waitFor restServer.closeWait()
    waitFor ben.chain.stopProcessingQueue()

  test "GET /identity should return 200 with JSON ClientVersion":
    let resp = fetchFull(HttpClientRequestRef.get(session, base & "/engine/v1/identity").get())
    check resp.status == 200
    check resp.contentType == "application/json"
    let parsed = parseJson(cast[string](resp.data))
    check parsed.kind == JArray
    check parsed[0]["code"].getStr == "NB"

  test "GET /identity with a bogus Eth-Execution-Version header should return 200":
    let resp = waitFor HttpClientRequestRef.get(session, base & "/engine/v1/identity",
      headers = @[("Eth-Execution-Version", "middle-earth")]).get().fetch()
    check resp[0] == 200

  test "GET /capabilities should return 200":
    let resp = fetchFull(HttpClientRequestRef.get(session, base & "/engine/v1/capabilities").get())
    check resp.status == 200
    check resp.contentType == "application/json"
    let parsed = parseJson(cast[string](resp.data))
    check parsed["supported_forks"].len == 6
    check parsed["limits"]["bodies.max_count"].getInt == MAX_BODIES_REQUEST
    check parsed["limits"]["blobs.max_versioned_hashes"].getInt == MAX_BLOBS_REQUEST
    check parsed["limits"]["payload.max_bytes"].getInt == MAX_REQUEST_BODY_SIZE

  test "POST /forkchoice with no Eth-Execution-Version header should return 400 unsupported-fork":
    let body = SSZ.encode(ForkchoiceUpdateParis(
      forkchoice_state: ForkchoiceState(head_block_hash: genesisDigest)))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "POST /forkchoice with bogus Eth-Execution-Version should return 400 unsupported-fork":
    let body = SSZ.encode(ForkchoiceUpdateParis(
      forkchoice_state: ForkchoiceState(head_block_hash: genesisDigest)))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[
        ("Eth-Execution-Version", "middle-earth"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "POST /forkchoice with missing request body should return 400 invalid-request":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = newSeq[byte]()).get().fetch()
    check resp[0] == 400
    check "invalid-request" in cast[string](resp[1])

  test "POST /forkchoice with garbage SSZ body should return 400 ssz-decode-error":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = @[byte 1, 2, 3]).get().fetch()
    check resp[0] == 400
    check "ssz-decode-error" in cast[string](resp[1])

  test "POST /forkchoice with wrong Content-Type should return 415 unsupported-media-type":
    let body = SSZ.encode(ForkchoiceUpdateParis(
      forkchoice_state: ForkchoiceState(head_block_hash: genesisDigest)))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "text/plain")],
      body = body).get().fetch()
    check resp[0] == 415
    check "unsupported-media-type" in cast[string](resp[1])

  test "POST /forkchoice with payload_attributes for an inactive fork should return 422 invalid-attributes":
    let body = SSZ.encode(ForkchoiceUpdateShanghai(
      forkchoice_state: ForkchoiceState(),
      payload_attributes: optSome(PayloadAttributesShanghai(timestamp: 1))))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[
        ("Eth-Execution-Version", "shanghai"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 422
    check "invalid-attributes" in cast[string](resp[1])

  test "POST /forkchoice with fork=paris, head=safe=finalized=genesis and payload_attributes should return 200 VALID":
    let body = SSZ.encode(ForkchoiceUpdateParis(
      forkchoice_state: ForkchoiceState(
        head_block_hash: genesisDigest,
        safe_block_hash: genesisDigest,
        finalized_block_hash: genesisDigest),
      payload_attributes: optSome(PayloadAttributesParis(
        timestamp: uint64(ben.com.genesisHeader.timestamp) + 1))))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 200
    let status = SSZ.decode(resp[1], ForkchoiceUpdateResponse)
    check status.payload_status.status == uint8(PayloadStatusCode.VALID)
    check status.payload_id.isSome
    payloadId = Bytes8(distinctBase(status.payload_id.get))
    payloadIdHex = "0x" & byteutils.toHex(distinctBase(payloadId))

  test "GET /payloads/{id} with no Eth-Execution-Version header should return 400 unsupported-fork":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/payloads/" & payloadIdHex).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "GET /payloads/{id} with a malformed payloadId (not hex) should return 400 invalid-request":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/payloads/not-hex",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 400
    check "invalid-request" in cast[string](resp[1])

  test "GET /payloads/{id} with a malformed payloadId (wrong length) should return 400 invalid-request":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/payloads/0x1234",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 400
    check "invalid-request" in cast[string](resp[1])

  test "GET /payloads/{id} with a well-formed but unknown payloadId should return 404 unknown-payload":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/payloads/0xdeadbeefdeadbeef",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 404
    check "unknown-payload" in cast[string](resp[1])

  test "GET /payloads/{id} with a fork-shape mismatch (built paris, requested cancun) should return 400 unsupported-fork":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/payloads/" & payloadIdHex,
      headers = @[("Eth-Execution-Version", "cancun")]).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "GET /payloads/{id} with fork=paris and a known id should return 200 with Cache-Control: no-store":
    let request = HttpClientRequestRef.get(session,
      base & "/engine/v1/payloads/" & payloadIdHex,
      headers = @[("Eth-Execution-Version", "paris")]).get()
    let response = waitFor request.send()
    check response.status == 200
    check response.headers.getString("Cache-Control") == "no-store"
    let data = waitFor response.getBodyBytes()
    waitFor response.closeWait()
    let built = SSZ.decode(data, BuiltPayloadParis)
    check built.payload.block_number == 1'u64 # child of genesis
    check built.payload.parent_hash == genesisDigest
    builtPayload = built.payload

  test "POST /payloads with no Eth-Execution-Version header should return 400 unsupported-fork":
    let body = SSZ.encode(ExecutionPayloadEnvelopeParis(payload: builtPayload))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/payloads",
      headers = @[("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "POST /payloads with a bogus Eth-Execution-Version should return 400 unsupported-fork":
    let body = SSZ.encode(ExecutionPayloadEnvelopeParis(payload: builtPayload))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/payloads",
      headers = @[
        ("Eth-Execution-Version", "middle-earth"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "POST /payloads with missing request body should return 400 invalid-request":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/payloads",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = newSeq[byte]()).get().fetch()
    check resp[0] == 400
    check "invalid-request" in cast[string](resp[1])

  test "POST /payloads with garbage SSZ body should return 400 ssz-decode-error":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/payloads",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = @[byte 1, 2, 3]).get().fetch()
    check resp[0] == 400
    check "ssz-decode-error" in cast[string](resp[1])

  test "POST /payloads with wrong Content-Type should return 415 unsupported-media-type":
    let body = SSZ.encode(ExecutionPayloadEnvelopeParis(payload: builtPayload))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/payloads",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/json")],
      body = body).get().fetch()
    check resp[0] == 415
    check "unsupported-media-type" in cast[string](resp[1])

  test "POST /payloads with a well-formed envelope for an inactive fork should return 422 invalid-body":
    let body = SSZ.encode(ExecutionPayloadEnvelopeShanghai(
      payload: ExecutionPayloadShanghai()))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/payloads",
      headers = @[
        ("Eth-Execution-Version", "shanghai"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 422
    check "invalid-body" in cast[string](resp[1])

  test "POST /payloads with the just-built payload should return 200 VALID (self-produced block)":
    let body = SSZ.encode(ExecutionPayloadEnvelopeParis(payload: builtPayload))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/payloads",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 200
    let status = SSZ.decode(resp[1], PayloadStatus)
    check status.status == uint8(PayloadStatusCode.VALID)

  test "POST /forkchoice with an inconsistent forkchoice state should return 409 invalid-forkchoice":
    # The block imported above is known to the chain but is not (yet) the
    # canonical head, so referencing it as for the FCU while pointing
    # finalized at an unrelated/unknown hash is an inconsistent state.
    let body = SSZ.encode(ForkchoiceUpdateParis(
      forkchoice_state: ForkchoiceState(
        head_block_hash: builtPayload.block_hash,
        finalized_block_hash: fakeDigest(0xaa))))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 409
    check "invalid-forkchoice" in cast[string](resp[1])

  test "POST /forkchoice with a zero head hash should return 200 INVALID":
    let body = SSZ.encode(ForkchoiceUpdateParis(
      forkchoice_state: ForkchoiceState(head_block_hash: default(Digest))))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/forkchoice",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 200
    let status = SSZ.decode(resp[1], ForkchoiceUpdateResponse)
    check status.payload_status.status == uint8(PayloadStatusCode.INVALID)

  test "POST /bodies/hash with no Eth-Execution-Version header should return 400 unsupported-fork":
    let body = SSZ.encode(BodiesByHashRequest(
      block_hashes: List[Digest, Limit MAX_BODIES_REQUEST].init(@[genesisDigest])))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/bodies/hash",
      headers = @[("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "POST /bodies/hash with missing request body should return 400 invalid-request":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/bodies/hash",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = newSeq[byte]()).get().fetch()
    check resp[0] == 400
    check "invalid-request" in cast[string](resp[1])

  test "POST /bodies/hash with garbage SSZ body should return 400 ssz-decode-error":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/bodies/hash",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = @[byte 1, 2, 3]).get().fetch()
    check resp[0] == 400
    check "ssz-decode-error" in cast[string](resp[1])

  test "POST /bodies/hash with known and unknown hashes should return 200 with unknown hash unavailable":
    var unknownHash: Digest
    unknownHash.data[0] = 0xff
    let body = SSZ.encode(BodiesByHashRequest(
      block_hashes: List[Digest, Limit MAX_BODIES_REQUEST].init(
        @[builtPayload.block_hash, builtPayload.parent_hash, unknownHash])))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/bodies/hash",
      headers = @[
        ("Eth-Execution-Version", "paris"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 200
    let response = SSZ.decode(resp[1], BodiesResponseParis)
    let entries = asSeq(response.entries)
    check entries.len == 3
    check entries[0].available == true
    check entries[1].available == true # genesis has empty-tx body, still available
    check entries[2].available == false # unknown hash

  test "GET /bodies with no Eth-Execution-Version header should return 400 unsupported-fork":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies?from=1&count=1").get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "GET /bodies with missing 'from' and 'count' should return 400 invalid-request":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 400
    check "invalid-request" in cast[string](resp[1])

  test "GET /bodies with missing 'count' should return 400 invalid-request":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies?from=1",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 400
    check "invalid-request" in cast[string](resp[1])

  test "GET /bodies with a non-numeric 'from' should return 400":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies?from=not-a-number&count=1",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 400

  test "GET /bodies with from=0 should return 422 invalid-body":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies?from=0&count=1",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 422

  test "GET /bodies with count=0 should return 422 invalid-body":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies?from=1&count=0",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 422

  test "GET /bodies with count exceeding MAX_BODIES_REQUEST should return 413 request-too-large":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies?from=1&count=" & $(MAX_BODIES_REQUEST + 1),
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 413
    check "request-too-large" in cast[string](resp[1])

  test "GET /bodies with from beyond head should return 200 with an empty entries list (truncated, not padded)":
    let resp = waitFor HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies?from=1000000&count=1",
      headers = @[("Eth-Execution-Version", "paris")]).get().fetch()
    check resp[0] == 200
    let response = SSZ.decode(resp[1], BodiesResponseParis)
    check asSeq(response.entries).len == 0

  test "GET /bodies with from=1 and count=1 should return 200 with block 1":
    let resp = fetchFull(HttpClientRequestRef.get(session,
      base & "/engine/v1/bodies?from=1&count=1",
      headers = @[("Eth-Execution-Version", "paris")]).get())
    check resp.status == 200
    check resp.contentType == "application/octet-stream"
    let response = SSZ.decode(resp.data, BodiesResponseParis)
    let entries = asSeq(response.entries)
    check entries.len == 1
    check entries[0].available == true
    check asSeq(entries[0].body.transactions).len == 0

  test "POST /blobs/v1 with missing request body should return 400 invalid-request":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/blobs/v1",
      headers = @[("Content-Type", "application/octet-stream")],
      body = newSeq[byte]()).get().fetch()
    check resp[0] == 400
    check "invalid-request" in cast[string](resp[1])

  test "POST /blobs/v1 with garbage SSZ body should return 400 ssz-decode-error":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/blobs/v1",
      headers = @[("Content-Type", "application/octet-stream")],
      body = @[byte 1, 2, 3]).get().fetch()
    check resp[0] == 400
    check "ssz-decode-error" in cast[string](resp[1])

  test "POST /blobs/v1 with no versioned hashes should return 200 with empty entries (Eth-Execution-Version ignored)":
    let body = SSZ.encode(BlobsRequest())
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/blobs/v1",
      headers = @[
        ("Eth-Execution-Version", "middle-earth"),
        ("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 200
    let response = SSZ.decode(resp[1], BlobsV1Response)
    check asSeq(response.entries).len == 0

  test "POST /blobs/v1 with an unknown versioned hash should return 200 with the entry present but unavailable":
    var unknownHash: Digest
    unknownHash.data[0] = 0xee
    let body = SSZ.encode(BlobsRequest(
      versioned_hashes: List[Digest, Limit MAX_BLOBS_REQUEST].init(@[unknownHash])))
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/blobs/v1",
      headers = @[("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 200
    let response = SSZ.decode(resp[1], BlobsV1Response)
    let entries = asSeq(response.entries)
    check entries.len == 1
    check entries[0].available == false

  test "POST /blobs/v2 with Osaka never activated should return 400 unsupported-fork":
    let body = SSZ.encode(BlobsRequest())
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/blobs/v2",
      headers = @[("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "POST /blobs/v2 with garbage SSZ body should return 400 ssz-decode-error":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/blobs/v2",
      headers = @[("Content-Type", "application/octet-stream")],
      body = @[byte 1, 2, 3]).get().fetch()
    check resp[0] == 400
    check "ssz-decode-error" in cast[string](resp[1])

  test "POST /blobs/v3 with Osaka never activated should return 400 unsupported-fork":
    let body = SSZ.encode(BlobsRequest())
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/blobs/v3",
      headers = @[("Content-Type", "application/octet-stream")],
      body = body).get().fetch()
    check resp[0] == 400
    check "unsupported-fork" in cast[string](resp[1])

  test "POST /blobs/v3 with garbage SSZ body should return 400 ssz-decode-error":
    let resp = waitFor HttpClientRequestRef.post(session, base & "/engine/v1/blobs/v3",
      headers = @[("Content-Type", "application/octet-stream")],
      body = @[byte 1, 2, 3]).get().fetch()
    check resp[0] == 400
    check "ssz-decode-error" in cast[string](resp[1])

suite "Engine SSZ API REST transport: production mounting":
  var keyBytes: array[32, byte]
  for i in 0 ..< keyBytes.len:
    keyBytes[i] = byte(i)
  let sharedKey = JwtSharedKey(keyBytes)
  let ben = setupBeaconEngine()

  let router = newEngineRestRouter(ben)
  var handlers: seq[RpcHandlerProc] = @[newEngineRestHandlerProc(router)]
  let hooks = @[httpJwtAuth(sharedKey)]
  let server = newHttpServerWithParams(
    initTAddress("127.0.0.1:0"), hooks, handlers).valueOr:
    raiseAssert "failed to start shared server: " & $error
  server.start()

  let base = "http://" & $server.localAddress()
  let session = HttpSessionRef.new()
  let goodToken = makeToken(sharedKey, getTime().toUnix)

  suiteTeardown:
    waitFor session.closeWait()
    waitFor server.closeWait()
    waitFor ben.chain.stopProcessingQueue()

  test "GET /engine/v1/identity with no Authorization header should return 401/403":
    let resp = waitFor HttpClientRequestRef.get(session, base & "/engine/v1/identity").get().fetch()
    check resp[0] == 401 or resp[0] == 403

  test "GET /engine/v1/identity with an expired JWT should return 401/403":
    let expiredToken = makeToken(sharedKey, getTime().toUnix - 3600)
    let resp = waitFor HttpClientRequestRef.get(session, base & "/engine/v1/identity",
      headers = [("Authorization", "Bearer " & expiredToken)]).get().fetch()
    check resp[0] == 401 or resp[0] == 403

  test "GET /engine/v1/identity with a malformed bearer token (not a JWT) should return 401/403":
    let resp = waitFor HttpClientRequestRef.get(session, base & "/engine/v1/identity",
      headers = [("Authorization", "Bearer not-a-jwt")]).get().fetch()
    check resp[0] == 401 or resp[0] == 403

  test "GET /engine/v1/identity with a missing 'Bearer ' scheme should return 401/403":
    let resp = waitFor HttpClientRequestRef.get(session, base & "/engine/v1/identity",
      headers = [("Authorization", goodToken)]).get().fetch()
    check resp[0] == 401 or resp[0] == 403

  test "GET /engine/v1/identity with a valid JWT should return 200":
    let resp = waitFor HttpClientRequestRef.get(session, base & "/engine/v1/identity",
      headers = [("Authorization", "Bearer " & goodToken)]).get().fetch()
    check resp[0] == 200
    let parsed = parseJson(cast[string](resp[1]))
    check parsed[0]["code"].getStr == "NB"
