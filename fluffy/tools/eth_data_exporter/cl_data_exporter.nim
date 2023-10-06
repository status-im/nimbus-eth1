# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles, chronos,
  stew/byteutils,
  eth/async_utils,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec//eth2_apis/rest_beacon_client,
  beacon_chain/beacon_clock,
  ../../network/beacon_light_client/beacon_light_client_content,
  ./exporter_common

export beacon_clock

const
  restRequestsTimeout = 30.seconds

proc getBeaconData*(): (
    RuntimeConfig, ref ForkDigests, BeaconClock) {.raises: [IOError].} =
  let
    metadata = getMetadataForNetwork("mainnet")
    genesisState =
      try:
        template genesisData(): auto = metadata.genesis.bakedBytes
        newClone(readSszForkedHashedBeaconState(
          metadata.cfg,
          genesisData.toOpenArray(genesisData.low, genesisData.high)))
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg
    genesis_validators_root =
      getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(
      metadata.cfg, genesis_validators_root)

    beaconClock = BeaconClock.init(getStateField(genesisState[], genesis_time))


  return (metadata.cfg, forkDigests, beaconClock)

func forkDigestAtEpoch(
    forkDigests: ForkDigests, epoch: Epoch, cfg: RuntimeConfig): ForkDigest =
  forkDigests.atEpoch(epoch, cfg)

proc exportLCBootstrapUpdate*(
    restUrl: string, dataDir: string,
    trustedBlockRoot: Eth2Digest,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests) {.async.} =
  let file = "light-client-bootstrap.json"
  let fh = createAndOpenFile(dataDir, file)

  defer:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occured while closing file", error = e.msg
      quit 1

  var
    client = RestClientRef.new(restUrl).valueOr:
      error "Cannot connect to server", error = error
      quit 1

  var contentTable: JsonPortalContentTable

  var update =
    try:
      notice "Downloading LC bootstrap"
      awaitWithTimeout(
        client.getLightClientBootstrap(
          trustedBlockRoot,
          cfg, forkDigests),
        restRequestsTimeout
      ):
        error "Attempt to download LC bootstrap timed out"
        quit 1
    except CatchableError as exc:
      error "Unable to download LC bootstrap", error = exc.msg
      quit 1

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.header.beacon.slot
        contentKey = encode(bootstrapContentKey(trustedBlockRoot))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(slot), cfg)
        content = encodeBootstrapForked(
          forkDigest,
          update
        )

      let portalContent = JsonPortalContent(
        content_key: contentKey.asSeq().to0xHex(),
        content_value: content.to0xHex()
      )

      var contentTable: JsonPortalContentTable
      contentTable[$slot] = portalContent

      writePortalContentToJson(fh, contentTable)

proc exportLCUpdates*(
    restUrl: string, dataDir: string,
    startPeriod: uint64, count: uint64,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests) {.async.} =
  let file = "light-client-updates.json"
  let fh = createAndOpenFile(dataDir, file)

  defer:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occured while closing file", error = e.msg
      quit 1

  var
    client = RestClientRef.new(restUrl).valueOr:
      error "Cannot connect to server", error = error
      quit 1

  var contentTable: JsonPortalContentTable

  var updates =
    try:
      notice "Downloading LC updates"
      awaitWithTimeout(
        client.getLightClientUpdatesByRange(
          SyncCommitteePeriod(startPeriod), count, cfg, forkDigests),
        restRequestsTimeout
      ):
        error "Attempt to download LC updates timed out"
        quit 1
    except CatchableError as exc:
      error "Unable to download LC updates", error = exc.msg
      quit 1

  if updates.len() > 0:
    withForkyObject(updates[0]):
      when lcDataFork > LightClientDataFork.None:
        let
          slot = forkyObject.attested_header.beacon.slot
          period = forkyObject.attested_header.beacon.slot.sync_committee_period
          contentKey = encode(updateContentKey(period.uint64, count))
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)

          content = encodeLightClientUpdatesForked(
            forkDigest,
            updates
          )


        let portalContent = JsonPortalContent(
          content_key: contentKey.asSeq().to0xHex(),
          content_value: content.to0xHex()
        )

        var contentTable: JsonPortalContentTable
        contentTable[$slot] = portalContent

        writePortalContentToJson(fh, contentTable)
  else:
    error "No updates downloaded"
    quit 1

proc exportLCFinalityUpdate*(
    restUrl: string, dataDir: string,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests) {.async.} =
  let file = "light-client-finality-update.json"
  let fh = createAndOpenFile(dataDir, file)

  defer:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occured while closing file", error = e.msg
      quit 1

  var
    client = RestClientRef.new(restUrl).valueOr:
      error "Cannot connect to server", error = error
      quit 1

  var contentTable: JsonPortalContentTable

  var update =
    try:
      notice "Downloading LC finality update"
      awaitWithTimeout(
        client.getLightClientFinalityUpdate(
          cfg, forkDigests),
        restRequestsTimeout
      ):
        error "Attempt to download LC finality update timed out"
        quit 1
    except CatchableError as exc:
      error "Unable to download LC finality update", error = exc.msg
      quit 1

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        finalizedSlot = forkyObject.finalized_header.beacon.slot
        contentKey = encode(finalityUpdateContentKey(finalizedSlot.uint64))
        contentId = beacon_light_client_content.toContentId(contentKey)
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
        content = encodeFinalityUpdateForked(
          forkDigest,
          update
        )

      let portalContent = JsonPortalContent(
        content_key: contentKey.asSeq().to0xHex(),
        content_value: content.to0xHex()
      )

      var contentTable: JsonPortalContentTable
      contentTable[$finalizedSlot] = portalContent

      writePortalContentToJson(fh, contentTable)

proc exportLCOptimisticUpdate*(
    restUrl: string, dataDir: string,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests) {.async.} =
  let file = "light-client-optimistic-update.json"
  let fh = createAndOpenFile(dataDir, file)

  defer:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occured while closing file", error = e.msg
      quit 1

  var
    client = RestClientRef.new(restUrl).valueOr:
      error "Cannot connect to server", error = error
      quit 1

  var contentTable: JsonPortalContentTable

  var update =
    try:
      notice "Downloading LC optimistic update"
      awaitWithTimeout(
        client.getLightClientOptimisticUpdate(
          cfg, forkDigests),
        restRequestsTimeout
      ):
        error "Attempt to download LC optimistic update timed out"
        quit 1
    except CatchableError as exc:
      error "Unable to download LC optimistic update", error = exc.msg
      quit 1

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.attested_header.beacon.slot
        contentKey = encode(optimisticUpdateContentKey(slot.uint64))
        contentId = beacon_light_client_content.toContentId(contentKey)
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
        content = encodeOptimisticUpdateForked(
          forkDigest,
          update
        )

      let portalContent = JsonPortalContent(
        content_key: contentKey.asSeq().to0xHex(),
        content_value: content.to0xHex()
      )

      var contentTable: JsonPortalContentTable
      contentTable[$slot] = portalContent

      writePortalContentToJson(fh, contentTable)
