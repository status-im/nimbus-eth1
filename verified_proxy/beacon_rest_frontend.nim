# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[strutils, uri],
  chronos,
  chronicles,
  presto/[route, server],
  beacon_chain/spec/forks,
  beacon_chain/rpc/rest_constants,
  ./engine/[types, beacon_frontend]

logScope:
  topics = "vp_beacon_frontend"

const
  jsonMediaType = MediaType.init("application/json")
  sszMediaType = MediaType.init("application/octet-stream")

type BeaconRestServer* = ref object
  router: RestRouter
  address: TransportAddress
  server: RestServerRef

func acceptAnyPattern(pattern: string, value: string): int =
  0

proc backendError(e: ErrorTuple): RestApiResponse =
  RestApiResponse.jsonError(Http503, $e.errType & ": " & e.errMsg)

proc versionedResponse[T: SomeForkedLightClientObject](
    v: RestVersioned[T], contentType: MediaType
): RestApiResponse =
  withForkyObject(v.data):
    when lcDataFork > LightClientDataFork.None:
      if contentType == sszMediaType:
        RestApiResponse.sszResponse(forkyObject, v.jsonVersion, false)
      else:
        RestApiResponse.jsonResponseWVersion(forkyObject, v.jsonVersion, false)
    else:
      RestApiResponse.jsonError(Http500, "light client object has no data")

proc init*(T: type BeaconRestServer, url: string): EngineResult[BeaconRestServer] =
  let
    parsedUrl = parseUri(url)
    hostname = if parsedUrl.hostname == "": "127.0.0.1" else: parsedUrl.hostname
    port =
      if parsedUrl.port == "":
        5052
      else:
        try:
          parseInt(parsedUrl.port)
        except ValueError:
          return err((FrontendError, "Could not parse the port number", UNTAGGED))

  if parsedUrl.scheme.toLowerAscii() notin ["http", "https"]:
    return err((FrontendError, "Invalid URL scheme: " & parsedUrl.scheme, UNTAGGED))

  let address =
    try:
      initTAddress(hostname, port)
    except TransportAddressError as e:
      return err((FrontendError, e.msg, UNTAGGED))

  ok(BeaconRestServer(router: RestRouter.init(acceptAnyPattern), address: address))

proc injectEngineFrontend*(server: BeaconRestServer, engine: RpcVerificationEngine) =
  let frontend = engine.getBeaconApiFrontend()

  server.router.api2(
    MethodGet, "/eth/v1/beacon/light_client/bootstrap/{block_root}"
  ) do(block_root: Eth2Digest) -> RestApiResponse:
    let contentType = preferredContentType(jsonMediaType, sszMediaType).valueOr:
      return RestApiResponse.jsonError(Http406, ContentNotAcceptableError)
    let blockRoot = block_root.valueOr:
      return RestApiResponse.jsonError(Http400, InvalidBlockRootValueError, $error)
    let bootstrap = (await frontend.getLightClientBootstrap(blockRoot)).valueOr:
      return backendError(error)
    let versioned = engine.versioned(bootstrap).valueOr:
      return RestApiResponse.jsonError(Http404, LCBootstrapUnavailable)
    versionedResponse(versioned, contentType)

  server.router.api2(MethodGet, "/eth/v1/beacon/light_client/updates") do(
    start_period: Option[SyncCommitteePeriod], count: Option[uint64]
  ) -> RestApiResponse:
    let contentType = preferredContentType(jsonMediaType, sszMediaType).valueOr:
      return RestApiResponse.jsonError(Http406, ContentNotAcceptableError)
    if start_period.isNone():
      return RestApiResponse.jsonError(Http400, MissingStartPeriodValueError)
    let startPeriod = start_period.get().valueOr:
      return RestApiResponse.jsonError(Http400, InvalidSyncPeriodError, $error)
    if count.isNone():
      return RestApiResponse.jsonError(Http400, MissingCountValueError)
    let numUpdates = count.get().valueOr:
      return RestApiResponse.jsonError(Http400, InvalidCountError, $error)
    let updates = (
      await frontend.getLightClientUpdatesByRange(startPeriod, numUpdates)
    ).valueOr:
      return backendError(error)

    let entries = engine.versioned(updates)
    if contentType == sszMediaType:
      RestApiResponse.sszResponseVersioned(entries)
    else:
      RestApiResponse.jsonResponseVersioned(entries)

  server.router.api2(
    MethodGet, "/eth/v1/beacon/light_client/finality_update"
  ) do() -> RestApiResponse:
    let contentType = preferredContentType(jsonMediaType, sszMediaType).valueOr:
      return RestApiResponse.jsonError(Http406, ContentNotAcceptableError)
    let update = (await frontend.getLightClientFinalityUpdate()).valueOr:
      return backendError(error)
    let versioned = engine.versioned(update).valueOr:
      return RestApiResponse.jsonError(Http404, LCFinUpdateUnavailable)
    versionedResponse(versioned, contentType)

  server.router.api2(
    MethodGet, "/eth/v1/beacon/light_client/optimistic_update"
  ) do() -> RestApiResponse:
    let contentType = preferredContentType(jsonMediaType, sszMediaType).valueOr:
      return RestApiResponse.jsonError(Http406, ContentNotAcceptableError)
    let update = (await frontend.getLightClientOptimisticUpdate()).valueOr:
      return backendError(error)
    let versioned = engine.versioned(update).valueOr:
      return RestApiResponse.jsonError(Http404, LCOptUpdateUnavailable)
    versionedResponse(versioned, contentType)

proc start*(server: BeaconRestServer): EngineResult[void] =
  server.server = RestServerRef.new(server.router, server.address, errorType = string).valueOr:
    return err((FrontendError, error, UNTAGGED))
  server.server.start()
  ok()

proc stop*(server: BeaconRestServer) {.async: (raises: []).} =
  if server.server != nil:
    await server.server.stop()
    await server.server.closeWait()
