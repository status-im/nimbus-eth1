# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[json, options, sequtils, strutils],
  presto,
  presto/serverprivate,
  chronos/apps/http/httptable,
  results,
  json_rpc/errors,
  web3/execution_types,
  beacon_chain/spec/datatypes/bellatrix,
  beacon_chain/spec/datatypes/capella,
  beacon_chain/spec/datatypes/deneb,
  ../version_info,
  ../utils/utils,
  ../beacon/beacon_engine,
  ../beacon/ssz_eth_conv,
  ../beacon/api_handler/api_utils,
  ../beacon/api_handler/api_forkchoice,
  ../beacon/api_handler/api_newpayload,
  ../beacon/api_handler/api_getpayload,
  ../beacon/api_handler/api_getbodies,
  ../beacon/api_handler/api_getblobs,
  ./jwt_auth,
  ./rpc_server,
  ./engine_ssz_conv

import beacon_chain/spec/engine_types as engine_ssz_types
import beacon_chain/spec/datatypes/gloas except PayloadStatus

export presto, jwt_auth

const
  EngineApiVersionHeader* = "Eth-Execution-Version"
  EngineApiClientVersionHeader* = "X-Engine-Client-Version"

func problemJson(status: HttpCode, errType: string, detail = ""): RestApiResponse =
  let body =
    if detail.len == 0: $(%*{"type": errType})
    else: $(%*{"type": errType, "detail": detail})
  RestApiResponse.error(status, body, "application/problem+json")

func unsupportedForkResponse*(detail = ""): RestApiResponse =
  problemJson(Http400, "/engine-api/errors/unsupported-fork", detail)

func sszDecodeErrorResponse*(): RestApiResponse =
  problemJson(Http400, "/engine-api/errors/ssz-decode-error")

func invalidRequestResponse*(detail = ""): RestApiResponse =
  problemJson(Http400, "/engine-api/errors/invalid-request", detail)

func unsupportedMediaTypeResponse*(detail = ""): RestApiResponse =
  problemJson(Http415, "/engine-api/errors/unsupported-media-type", detail)

func internalErrorResponse*(detail = ""): RestApiResponse =
  problemJson(Http500, "/engine-api/errors/internal", detail)

func applicationErrorToRest*(e: ref ApplicationError): RestApiResponse =
  case e.code
  of engineApiParseError: problemJson(Http400, "/engine-api/errors/parse-error", e.msg)
  of engineApiInvalidRequest: problemJson(Http400, "/engine-api/errors/invalid-request", e.msg)
  of engineApiInvalidParams: problemJson(Http422, "/engine-api/errors/invalid-body", e.msg)
  of engineApiUnknownPayload: problemJson(Http404, "/engine-api/errors/unknown-payload", e.msg)
  of engineApiInvalidForkchoiceState: problemJson(Http409, "/engine-api/errors/invalid-forkchoice", e.msg)
  of engineApiInvalidPayloadAttributes: problemJson(Http422, "/engine-api/errors/invalid-attributes", e.msg)
  of engineApiTooDeepReorg: problemJson(Http409, "/engine-api/errors/too-deep-reorg", e.msg)
  of engineApiTooLargeRequest: problemJson(Http413, "/engine-api/errors/request-too-large", e.msg)
  of engineApiUnsupportedFork: problemJson(Http400, "/engine-api/errors/unsupported-fork", e.msg)
  else: problemJson(Http500, "/engine-api/errors/internal", e.msg)

proc checkBearerAuth*(request: HttpRequestRef, key: JwtSharedKey): Result[void, RestApiResponse] =
  let auth = request.headers.getString("Authorization", "?")
  if auth.len < 9 or auth[0 .. 6].cmpIgnoreCase("Bearer ") != 0:
    return err(RestApiResponse.error(Http403, "Missing authorization token"))

  let rc = auth[7 ..^ 1].strip.verifyTokenHS256(key)
  if rc.isOk:
    return ok()

  case rc.error
  of jwtTokenValidationError, jwtMethodUnsupported:
    err(RestApiResponse.error(Http401, "Unauthorized access"))
  else:
    err(RestApiResponse.error(Http403, "Malformed token"))

func getEngineFork*(request: HttpRequestRef): Result[EngineFork, RestApiResponse] =
  let header = request.headers.getString(EngineApiVersionHeader, "")
  if header.len == 0:
    return err(unsupportedForkResponse("missing " & EngineApiVersionHeader & " header"))
  let fork = parseEngineFork(header).valueOr:
    return err(unsupportedForkResponse("unrecognised fork: " & header))
  ok(fork)

func getClientVersionHeader*(request: HttpRequestRef): Opt[string] =
  let header = request.headers.getString(EngineApiClientVersionHeader, "")
  if header.len == 0: Opt.none(string) else: Opt.some(header)

const OctetStreamMediaType = MediaType.init("application", "octet-stream")

func checkOctetStream*(contentBody: ContentBody): Result[void, RestApiResponse] =
  if contentBody.contentType != OctetStreamMediaType:
    return err(unsupportedMediaTypeResponse(
      "expected Content-Type: application/octet-stream"))
  ok()

proc decodeForkchoiceUpdate(fork: EngineFork, data: seq[byte]):
    Result[tuple[fcState: ForkchoiceState, attrs: Opt[ForkedPayloadAttributes],
      custodyColumns: Optional[BitArray[engine_ssz_types.CELLS_PER_EXT_BLOB]]], RestApiResponse] =
  try:
    case fork
    of EngineFork.Paris:
      let body = SSZ.decode(data, ForkchoiceUpdateParis)
      let attrs =
        if body.payload_attributes.isSome:
          Opt.some(ForkedPayloadAttributes(fork: fork, parisData: body.payload_attributes.get))
        else: Opt.none(ForkedPayloadAttributes)
      ok((body.forkchoice_state, attrs, optNone(BitArray[engine_ssz_types.CELLS_PER_EXT_BLOB])))
    of EngineFork.Shanghai:
      let body = SSZ.decode(data, ForkchoiceUpdateShanghai)
      let attrs =
        if body.payload_attributes.isSome:
          Opt.some(ForkedPayloadAttributes(fork: fork, shanghaiData: body.payload_attributes.get))
        else: Opt.none(ForkedPayloadAttributes)
      ok((body.forkchoice_state, attrs, optNone(BitArray[engine_ssz_types.CELLS_PER_EXT_BLOB])))
    of EngineFork.Cancun, EngineFork.Prague, EngineFork.Osaka:
      let body = SSZ.decode(data, ForkchoiceUpdateCancun)
      let attrs =
        if body.payload_attributes.isSome:
          Opt.some(ForkedPayloadAttributes(fork: fork, cancunData: body.payload_attributes.get))
        else: Opt.none(ForkedPayloadAttributes)
      ok((body.forkchoice_state, attrs, optNone(BitArray[engine_ssz_types.CELLS_PER_EXT_BLOB])))
    of EngineFork.Amsterdam:
      let body = SSZ.decode(data, ForkchoiceUpdateAmsterdam)
      let attrs =
        if body.payload_attributes.isSome:
          Opt.some(ForkedPayloadAttributes(fork: fork, amsterdamData: body.payload_attributes.get))
        else: Opt.none(ForkedPayloadAttributes)
      ok((body.forkchoice_state, attrs, body.custody_columns))
  except CatchableError:
    err(sszDecodeErrorResponse())

proc handleForkchoiceUpdate(ben: BeaconEngineRef, request: HttpRequestRef,
    contentBody: Option[ContentBody]):
      Future[RestApiResponse] {.async: (raises: [CancelledError]).} =
  let fork = getEngineFork(request).valueOr:
    return error
  if contentBody.isNone:
    return invalidRequestResponse("missing request body")
  checkOctetStream(contentBody.get()).isOkOr:
    return error
  let (fcState, attrs, custodyColumns) =
    decodeForkchoiceUpdate(fork, contentBody.get().data).valueOr:
      return error
  try:
    let resp = await ben.forkchoiceUpdated(fork, fcState, attrs, custodyColumns)
    RestApiResponse.response(
      SSZ.encode(resp), Http200, "application/octet-stream")
  except ApplicationError as e:
    applicationErrorToRest(e)

proc handleNewPayload(ben: BeaconEngineRef, request: HttpRequestRef,
    contentBody: Option[ContentBody]):
      Future[RestApiResponse] {.async: (raises: [CancelledError]).} =
  let fork = getEngineFork(request).valueOr:
    return error
  if contentBody.isNone:
    return invalidRequestResponse("missing request body")
  checkOctetStream(contentBody.get()).isOkOr:
    return error
  let data = contentBody.get().data
  var status: PayloadStatus
  try:
    case fork
    of EngineFork.Paris:
      let body =
        try: SSZ.decode(data, ExecutionPayloadEnvelopeParis)
        except CatchableError: return sszDecodeErrorResponse()
      status = await ben.newPayload(fork, body.payload, Opt.none(BlockAccessListRef),
        Opt.none(Hash32), Opt.none(seq[seq[byte]]))
    of EngineFork.Shanghai:
      let body =
        try: SSZ.decode(data, ExecutionPayloadEnvelopeShanghai)
        except CatchableError: return sszDecodeErrorResponse()
      status = await ben.newPayload(fork, body.payload, Opt.none(BlockAccessListRef),
        Opt.none(Hash32), Opt.none(seq[seq[byte]]))
    of EngineFork.Cancun:
      let body =
        try: SSZ.decode(data, ExecutionPayloadEnvelopeCancun)
        except CatchableError: return sszDecodeErrorResponse()
      let beaconRoot = Opt.some(toHash32(body.parent_beacon_block_root))
      status = await ben.newPayload(fork, body.payload, Opt.none(BlockAccessListRef),
        beaconRoot, Opt.none(seq[seq[byte]]))
    of EngineFork.Prague:
      let body =
        try: SSZ.decode(data, ExecutionPayloadEnvelopePrague)
        except CatchableError: return sszDecodeErrorResponse()
      let beaconRoot = Opt.some(toHash32(body.parent_beacon_block_root))
      let executionRequests = Opt.some(ethExecutionRequests(body.execution_requests))
      status = await ben.newPayload(fork, body.payload, Opt.none(BlockAccessListRef),
        beaconRoot, executionRequests)
    of EngineFork.Osaka:
      let body =
        try: SSZ.decode(data, ExecutionPayloadEnvelopeOsaka)
        except CatchableError: return sszDecodeErrorResponse()
      let beaconRoot = Opt.some(toHash32(body.parent_beacon_block_root))
      let executionRequests = Opt.some(ethExecutionRequests(body.execution_requests))
      status = await ben.newPayload(fork, body.payload, Opt.none(BlockAccessListRef),
        beaconRoot, executionRequests)
    of EngineFork.Amsterdam:
      let body =
        try: SSZ.decode(data, ExecutionPayloadEnvelopeAmsterdam)
        except CatchableError: return sszDecodeErrorResponse()
      let beaconRoot = Opt.some(toHash32(body.parent_beacon_block_root))
      let executionRequests = Opt.some(ethExecutionRequests(body.execution_requests))
      status = await ben.newPayload(fork, body.payload, ethBlockAccessList(body.payload),
        beaconRoot, executionRequests)
    RestApiResponse.response(SSZ.encode(status), Http200, "application/octet-stream")
  except ApplicationError as e:
    applicationErrorToRest(e)
  except RlpError as e:
    invalidRequestResponse("failed to decode block in payload: " & e.msg)

proc decodePayloadId(raw: string): Result[Bytes8, RestApiResponse] =
  try:
    ok(Bytes8.fromHex(raw))
  except ValueError:
    err(invalidRequestResponse("malformed payloadId: expected 8-byte hex"))

proc handleGetPayload(ben: BeaconEngineRef, request: HttpRequestRef,
    payloadIdStr: string): RestApiResponse =
  let fork = getEngineFork(request).valueOr:
    return error
  let id = decodePayloadId(payloadIdStr).valueOr:
    return error
  try:
    let bytes =
      case fork
      of EngineFork.Paris:
        let bundle = ben.getPayload(fork, id)
        SSZ.encode(BuiltPayloadParis(
          payload: sszPayload[ExecutionPayloadParis](bundle.blk), block_value: bundle.blockValue))
      of EngineFork.Shanghai:
        let bundle = ben.getPayload(fork, id)
        SSZ.encode(BuiltPayloadShanghai(
          payload: sszPayload[ExecutionPayloadShanghai](bundle.blk), block_value: bundle.blockValue))
      of EngineFork.Cancun:
        let bundle = ben.getPayload(fork, id)
        SSZ.encode(BuiltPayloadCancun(
          payload: sszPayload[ExecutionPayloadCancun](bundle.blk), block_value: bundle.blockValue,
          blobs_bundle: sszBlobsBundleV1(bundle.blobsBundle),
          should_override_builder: false))
      of EngineFork.Prague:
        let bundle = ben.getPayload(fork, id)
        SSZ.encode(BuiltPayloadPrague(
          payload: sszPayload[ExecutionPayloadPrague](bundle.blk), block_value: bundle.blockValue,
          blobs_bundle: sszBlobsBundleV1(bundle.blobsBundle),
          execution_requests: sszExecutionRequests(bundle.executionRequests.get),
          should_override_builder: false))
      of EngineFork.Osaka:
        let bundle = ben.getPayload(fork, id)
        SSZ.encode(BuiltPayloadOsaka(
          payload: sszPayload[ExecutionPayloadOsaka](bundle.blk), block_value: bundle.blockValue,
          blobs_bundle: sszBlobsBundleV2(bundle.blobsBundle),
          execution_requests: sszExecutionRequests(bundle.executionRequests.get),
          should_override_builder: false))
      of EngineFork.Amsterdam:
        let bundle = ben.getPayload(fork, id)
        SSZ.encode(BuiltPayloadAmsterdam(
          payload: sszPayload[ExecutionPayloadAmsterdam](bundle.blk, bundle.blockAccessList),
          block_value: bundle.blockValue,
          blobs_bundle: sszBlobsBundleV2(bundle.blobsBundle),
          execution_requests: sszExecutionRequests(bundle.executionRequests.get),
          should_override_builder: false))
    RestApiResponse.response(bytes, Http200, "application/octet-stream",
      headers = [("Cache-Control", "no-store")])
  except ApplicationError as e:
    applicationErrorToRest(e)
  except CatchableError as e:
    internalErrorResponse(e.msg)

# FIXME: doesn't set available=false for cross fork queries yet.
proc decodeBodiesByHashRequest(data: seq[byte]): Result[seq[Hash32], RestApiResponse] =
  try:
    let body = SSZ.decode(data, BodiesByHashRequest)
    ok(asSeq(body.block_hashes).mapIt(toHash32(it)))
  except CatchableError:
    err(sszDecodeErrorResponse())

proc encodeBodiesResponseSsz(
    fork: EngineFork, bodies: seq[Opt[(Block, Opt[BlockAccessListRef])]]): seq[byte] =
  case fork
  of EngineFork.Paris:
    let entries = bodies.mapIt(
      block:
        if it.isSome: BodyEntryParis(available: true, body: sszBody[ExecutionPayloadBodyParis](it.get[0]))
        else: BodyEntryParis(available: false))
    SSZ.encode(BodiesResponseParis(
      entries: List[BodyEntryParis, Limit MAX_BODIES_REQUEST].init(entries)))
  of EngineFork.Amsterdam:
    let entries = bodies.mapIt(
      block:
        if it.isSome:
          BodyEntryAmsterdam(available: true,
            body: sszBody[ExecutionPayloadBodyAmsterdam](it.get[0], it.get[1]))
        else: BodyEntryAmsterdam(available: false))
    SSZ.encode(BodiesResponseAmsterdam(
      entries: List[BodyEntryAmsterdam, Limit MAX_BODIES_REQUEST].init(entries)))
  else:
    let entries = bodies.mapIt(
      block:
        if it.isSome: BodyEntryShanghai(available: true, body: sszBody[ExecutionPayloadBodyShanghai](it.get[0]))
        else: BodyEntryShanghai(available: false))
    SSZ.encode(BodiesResponseShanghai(
      entries: List[BodyEntryShanghai, Limit MAX_BODIES_REQUEST].init(entries)))

proc handleBodiesByHash(ben: BeaconEngineRef, request: HttpRequestRef,
    contentBody: Option[ContentBody]): RestApiResponse =
  let fork = getEngineFork(request).valueOr:
    return error
  if contentBody.isNone:
    return invalidRequestResponse("missing request body")
  checkOctetStream(contentBody.get()).isOkOr:
    return error
  let hashes = decodeBodiesByHashRequest(contentBody.get().data).valueOr:
    return error
  try:
    let bodies = ben.getPayloadBodiesByHash(hashes, withBlockAccessList = fork == EngineFork.Amsterdam)
    RestApiResponse.response(
      encodeBodiesResponseSsz(fork, bodies),
      Http200, "application/octet-stream")
  except ApplicationError as e:
    applicationErrorToRest(e)
  except CatchableError as e:
    internalErrorResponse(e.msg)

proc handleBodiesByRange(ben: BeaconEngineRef, request: HttpRequestRef,
    startBlock, blockCount: uint64): RestApiResponse =
  let fork = getEngineFork(request).valueOr:
    return error
  try:
    let bodies = ben.getPayloadBodiesByRange(
      startBlock, blockCount, withBlockAccessList = fork == EngineFork.Amsterdam)
    RestApiResponse.response(
      encodeBodiesResponseSsz(fork, bodies),
      Http200, "application/octet-stream")
  except ApplicationError as e:
    applicationErrorToRest(e)
  except CatchableError as e:
    internalErrorResponse(e.msg)

func decodeString*(t: typedesc[uint64], value: string): Result[uint64, cstring] =
  try:
    ok(parseBiggestUInt(value).uint64)
  except ValueError:
    err("invalid uint64")

proc decodeBlobsRequest(data: seq[byte]): Result[seq[VersionedHash], RestApiResponse] =
  try:
    let body = SSZ.decode(data, BlobsRequest)
    ok(asSeq(body.versioned_hashes).mapIt(toHash32(it)))
  except CatchableError:
    err(sszDecodeErrorResponse())

proc handleBlobsV1(ben: BeaconEngineRef, contentBody: Option[ContentBody]): RestApiResponse =
  if contentBody.isNone:
    return invalidRequestResponse("missing request body")
  checkOctetStream(contentBody.get()).isOkOr:
    return error
  let hashes = decodeBlobsRequest(contentBody.get().data).valueOr:
    return error
  try:
    RestApiResponse.response(
      SSZ.encode(ben.getBlobsAndProofsV1(hashes)),
      Http200, "application/octet-stream")
  except ApplicationError as e:
    applicationErrorToRest(e)

proc handleBlobsV2(ben: BeaconEngineRef, contentBody: Option[ContentBody]): RestApiResponse =
  if contentBody.isNone:
    return invalidRequestResponse("missing request body")
  checkOctetStream(contentBody.get()).isOkOr:
    return error
  let hashes = decodeBlobsRequest(contentBody.get().data).valueOr:
    return error
  try:
    let resp = ben.getBlobsAndProofsV2(hashes).valueOr:
      return RestApiResponse.response(Http204)
    RestApiResponse.response(
      SSZ.encode(resp), Http200, "application/octet-stream")
  except ApplicationError as e:
    applicationErrorToRest(e)

proc handleBlobsV3(ben: BeaconEngineRef, contentBody: Option[ContentBody]): RestApiResponse =
  if contentBody.isNone:
    return invalidRequestResponse("missing request body")
  checkOctetStream(contentBody.get()).isOkOr:
    return error
  let hashes = decodeBlobsRequest(contentBody.get().data).valueOr:
    return error
  try:
    RestApiResponse.response(
      SSZ.encode(ben.getBlobsAndProofsV3(hashes)),
      Http200, "application/octet-stream")
  except ApplicationError as e:
    applicationErrorToRest(e)

proc capabilitiesJson(): string =
  $(%*{
    "supported_forks": ["paris", "shanghai", "cancun", "prague", "osaka", "amsterdam"],
    "fork_scoped_endpoints": ["forkchoice", "payloads", "bodies"],
    "independently_versioned": {"blobs": ["v1", "v2", "v3"]}, # v4 (Amsterdam cell-range selection) not wired up yet.
    "unscoped_endpoints": ["capabilities", "identity"],
    "limits": {
      "bodies.max_count": MAX_BODIES_REQUEST,
      "blobs.max_versioned_hashes": MAX_BLOBS_REQUEST,
      "payload.max_bytes": MAX_REQUEST_BODY_SIZE
    }
  })

proc identityJson(): string =
  $(%*[{
    "code": "NB",
    "name": NimbusName,
    "version": NimbusVersion,
    "commit": GitRevision
  }])

func decodeString*(t: typedesc[string], value: string): Result[string, cstring] =
  ok(value)

func noopPatternValidator(pattern: string, value: string): int {.gcsafe, raises: [].} =
  0

proc newEngineRestRouter*(ben: BeaconEngineRef): RestRouter =
  var router = RestRouter.init(noopPatternValidator)

  router.api2(MethodGet, "/engine/v1/identity") do () -> RestApiResponse:
    RestApiResponse.response(identityJson(), Http200, "application/json")

  router.api2(MethodGet, "/engine/v1/capabilities") do () -> RestApiResponse:
    RestApiResponse.response(capabilitiesJson(), Http200, "application/json")

  router.api2(MethodPost, "/engine/v1/forkchoice") do (
      contentBody: Option[ContentBody]) -> RestApiResponse:
    await handleForkchoiceUpdate(ben, request, contentBody)

  router.api2(MethodPost, "/engine/v1/payloads") do (
      contentBody: Option[ContentBody]) -> RestApiResponse:
    await handleNewPayload(ben, request, contentBody)

  router.api2(MethodGet, "/engine/v1/payloads/{payloadId}") do (
      payloadId: string) -> RestApiResponse:
    let payloadIdStr = payloadId.valueOr:
      return invalidRequestResponse("malformed payloadId path segment")
    handleGetPayload(ben, request, payloadIdStr)

  router.api2(MethodPost, "/engine/v1/bodies/hash") do (
      contentBody: Option[ContentBody]) -> RestApiResponse:
    handleBodiesByHash(ben, request, contentBody)

  router.api2(MethodGet, "/engine/v1/bodies") do (
      `from`: Option[uint64], count: Option[uint64]) -> RestApiResponse:
    if `from`.isNone or count.isNone:
      return invalidRequestResponse("missing 'from'/'count' query parameter")
    let startBlock = `from`.get.valueOr:
      return invalidRequestResponse("invalid 'from' query parameter")
    let blockCount = count.get.valueOr:
      return invalidRequestResponse("invalid 'count' query parameter")
    handleBodiesByRange(ben, request, startBlock, blockCount)

  router.api2(MethodPost, "/engine/v1/blobs/v1") do (
      contentBody: Option[ContentBody]) -> RestApiResponse:
    handleBlobsV1(ben, contentBody)

  router.api2(MethodPost, "/engine/v1/blobs/v2") do (
      contentBody: Option[ContentBody]) -> RestApiResponse:
    handleBlobsV2(ben, contentBody)

  router.api2(MethodPost, "/engine/v1/blobs/v3") do (
      contentBody: Option[ContentBody]) -> RestApiResponse:
    handleBlobsV3(ben, contentBody)

  router

proc newEngineRestHandlerProc*(router: RestRouter): RpcHandlerProc =
  let server = RestServerRef(router: router)

  proc handlerProc(request: HttpRequestRef): Future[RpcHandlerResult] {.async: (raises: []).} =
    if not request.uri.path.startsWith("/engine/v1/"):
      return RpcHandlerResult(status: RpcHandlerStatus.Skip)
    try:
      let resp = await processRestRequest(server, RequestFence.ok(request))
      RpcHandlerResult(status: RpcHandlerStatus.Response, response: resp)
    except CancelledError:
      RpcHandlerResult(status: RpcHandlerStatus.Error)

  handlerProc

proc initEngineRestServer*(
    ben: BeaconEngineRef,
    address: TransportAddress,
    maxRequestBodySize = MAX_REQUEST_BODY_SIZE
): Result[RestServerRef, string] =
  let res = RestServerRef.new(
    newEngineRestRouter(ben), address,
    serverFlags = {HttpServerFlags.NotifyDisconnect},
    maxRequestBodySize = maxRequestBodySize)
  if res.isErr():
    return err($res.error())
  ok(res.get())
