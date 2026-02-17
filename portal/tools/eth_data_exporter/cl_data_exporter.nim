# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  chronicles,
  chronos,
  stew/[byteutils, io2],
  eth/async_utils,
  eth/common/headers_rlp,
  json_rpc/rpcclient,
  beacon_chain/era_db,
  beacon_chain/spec/forks,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/eth2_apis/rest_beacon_client,
  beacon_chain/beacon_clock,
  ../../network/beacon/beacon_content,
  ../../network/beacon/beacon_init_loader,
  ../../eth_history/block_proofs/block_proof_historical_roots,
  ../../eth_history/block_proofs/block_proof_historical_summaries,
  ../../eth_history/[yaml_utils, yaml_eth_types],
  ../../network/network_metadata,
  ./exporter_common

export beacon_clock

const
  largeRequestsTimeout = 120.seconds # For downloading large items such as states.
  restRequestsTimeout = 30.seconds

proc getBeaconData*(): (RuntimeConfig, ref ForkDigests, BeaconClock) =
  let
    metadata = getMetadataForNetwork("mainnet")
    genesisState =
      try:
        template genesisData(): auto =
          metadata.genesis.bakedBytes

        newClone(
          readSszForkedHashedBeaconState(
            metadata.cfg, genesisData.toOpenArray(genesisData.low, genesisData.high)
          )
        )
      except SerializationError as err:
        raiseAssert "Invalid baked-in state: " & err.msg
    genesis_validators_root = genesisState[].genesis_validators_root
    forkDigests = newClone ForkDigests.init(metadata.cfg, genesis_validators_root)

    genesisTime = genesisState[].genesis_time
    beaconClock = BeaconClock.init(metadata.cfg.timeParams, genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure

  return (metadata.cfg, forkDigests, beaconClock)

proc exportLCBootstrapUpdate*(
    restUrl: string,
    dataDir: string,
    trustedBlockRoot: Eth2Digest,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
) {.async.} =
  let fileName = "light-client-bootstrap-" & $trustedBlockRoot.data.toHex() & ".yaml"
  existsFile(dataDir, fileName)

  let client = RestClientRef.new(restUrl).valueOr:
    error "Cannot connect to server", error = error
    quit 1

  let update =
    try:
      notice "Downloading LC bootstrap"
      awaitWithTimeout(
        client.getLightClientBootstrap(trustedBlockRoot, cfg, forkDigests),
        restRequestsTimeout,
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
        forkDigest = forkDigestAtEpoch(forkDigests[], epoch(slot), cfg)
        content = encodeBootstrapForked(forkDigest, update)

        file = dataDir / fileName
      writePortalContentToYaml(file, contentKey.asSeq().to0xHex(), content.to0xHex())

proc exportLCUpdates*(
    restUrl: string,
    dataDir: string,
    startPeriod: uint64,
    count: uint64,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
) {.async.} =
  let fileName = "light-client-updates-" & $startPeriod & "-" & $count & ".yaml"
  existsFile(dataDir, fileName)

  let client = RestClientRef.new(restUrl).valueOr:
    error "Cannot connect to server", error = error
    quit 1

  let updates =
    try:
      notice "Downloading LC updates"
      awaitWithTimeout(
        client.getLightClientUpdatesByRange(
          SyncCommitteePeriod(startPeriod), count, cfg, forkDigests
        ),
        restRequestsTimeout,
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
          period = forkyObject.attested_header.beacon.slot.sync_committee_period
          contentKey = encode(updateContentKey(period.uint64, count))
          content = encodeLightClientUpdatesForked(
            ForkedLightClientUpdateList.init(updates), forkDigests[], cfg
          )

          file = dataDir / fileName
        writePortalContentToYaml(file, contentKey.asSeq().to0xHex(), content.to0xHex())
  else:
    error "No updates downloaded"
    quit 1

proc exportLCFinalityUpdate*(
    restUrl: string, dataDir: string, cfg: RuntimeConfig, forkDigests: ref ForkDigests
) {.async.} =
  let fileName = "light-client-finality-update.yaml"
  existsFile(dataDir, fileName)

  let client = RestClientRef.new(restUrl).valueOr:
    error "Cannot connect to server", error = error
    quit 1

  let update =
    try:
      notice "Downloading LC finality update"
      awaitWithTimeout(
        client.getLightClientFinalityUpdate(cfg, forkDigests), restRequestsTimeout
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
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg
        )
        content = encodeFinalityUpdateForked(forkDigest, update)

        file = dataDir / fileName
      writePortalContentToYaml(file, contentKey.asSeq().to0xHex(), content.to0xHex())

proc exportLCOptimisticUpdate*(
    restUrl: string, dataDir: string, cfg: RuntimeConfig, forkDigests: ref ForkDigests
) {.async.} =
  let fileName = "light-client-optimistic-update.yaml"
  existsFile(dataDir, fileName)

  let client = RestClientRef.new(restUrl).valueOr:
    error "Cannot connect to server", error = error
    quit 1

  let update =
    try:
      notice "Downloading LC optimistic update"
      awaitWithTimeout(
        client.getLightClientOptimisticUpdate(cfg, forkDigests), restRequestsTimeout
      ):
        error "Attempt to download LC optimistic update timed out"
        quit 1
    except CatchableError as exc:
      error "Unable to download LC optimistic update", error = exc.msg
      quit 1

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.signature_slot
        contentKey = encode(optimisticUpdateContentKey(slot.uint64))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg
        )
        content = encodeOptimisticUpdateForked(forkDigest, update)

        file = dataDir / fileName
      writePortalContentToYaml(file, contentKey.asSeq().to0xHex(), content.to0xHex())

proc exportHistoricalRoots*(
    restUrl: string, dataDir: string, cfg: RuntimeConfig, forkDigests: ref ForkDigests
) {.async.} =
  let file = dataDir / "historical_roots.ssz"
  if isFile(file):
    notice "Not downloading historical_roots, file already exists", file
    quit 1

  let client = RestClientRef.new(restUrl).valueOr:
    error "Cannot connect to server", error
    quit 1

  let state =
    try:
      notice "Downloading beacon state"
      awaitWithTimeout(
        client.getStateV2(StateIdent.init(StateIdentType.Finalized), cfg),
        largeRequestsTimeout,
      ):
        error "Attempt to download beacon state timed out"
        quit 1
    except CatchableError as exc:
      error "Unable to download beacon state", error = exc.msg
      quit 1

  if state == nil:
    error "No beacon state found"
    quit 1

  let historical_roots = state[].historical_roots

  let res = io2.writeFile(file, SSZ.encode(historical_roots))
  if res.isErr():
    error "Failed writing historical_roots to file", file, error = ioErrorMsg(res.error)
    quit 1
  else:
    notice "Succesfully wrote historical_roots to file", file

proc writeToFile(file: string, data: openArray[byte]) =
  let res = io2.writeFile(file, data)
  if res.isErr():
    error "Failed writing data to file", file, error = ioErrorMsg(res.error)
    quit QuitFailure
  else:
    notice "Successfully wrote data to file", file

proc getBlockProofBellatrix(
    dataDir: string, eraDir: string, slotNumber: uint64
): (BlockProofHistoricalRoots, uint64, Hash32) =
  let
    networkData = loadNetworkData("mainnet")
    db =
      EraDB.new(networkData.metadata.cfg, eraDir, networkData.genesis_validators_root)
    historical_roots = loadHistoricalRoots().asSeq()
    slot = Slot(slotNumber)
    era = era(slot)

  # Note: Provide just empty historical_summaries here as this is only
  # supposed to generate proofs for Bellatrix.
  var state: ForkedHashedBeaconState
  db.getState(historical_roots, [], start_slot(era + 1), state).isOkOr:
    error "Failed to load state", error = error
    quit QuitFailure

  let
    batch = HistoricalBatch(
      block_roots: state.block_roots.data, state_roots: state.state_roots.data
    )

    beaconBlock = db.getBlock(
      historical_roots,
      [],
      slot,
      Opt.none(Eth2Digest),
      bellatrix.TrustedSignedBeaconBlock,
    ).valueOr:
      error "Failed to load Bellatrix block", slot
      quit QuitFailure

    blockProof = block_proof_historical_roots.buildProof(batch, beaconBlock.message).valueOr:
      error "Failed to build proof for Bellatrix block", slot, error
      quit QuitFailure

    blockNumber = beaconBlock.message.body.execution_payload.block_number
    blockHash = beaconBlock.message.body.execution_payload.block_hash.to(Hash32)

  # Writing block.ssz and historical_batch.ssz to be able to regenerate this proof
  let blockFileName = dataDir / "block_at_slot_" & $blockProof.slot & ".ssz"
  writeToFile(blockFileName, SSZ.encode(beaconBlock.message))

  let batchFileName = dataDir / "historical_batch_at_slot_" & $blockProof.slot & ".ssz"
  writeToFile(batchFileName, SSZ.encode(batch))

  (blockProof, blockNumber, blockHash)

proc latestEraFile(eraDir: string): Result[(string, Era), string] =
  ## Find the latest era file in the era directory.
  var
    latestEra = 0
    latestEraFile = ""

  try:
    for kind, obj in walkDir eraDir:
      let (_, name, _) = splitFile(obj)
      let parts = name.split('-')
      if parts.len() == 3 and parts[0] == "mainnet":
        let era =
          try:
            parseInt(parts[1])
          except ValueError:
            return err("Invalid era number")
        if era > latestEra:
          latestEra = era
          latestEraFile = obj
  except OSError as e:
    return err(e.msg)

  if latestEraFile == "":
    err("No valid era files found")
  else:
    ok((latestEraFile, Era(latestEra)))

proc loadHistoricalSummariesFromEra(
    eraDir: string, cfg: RuntimeConfig
): Result[(HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT], Slot), string] =
  ## Load the historical_summaries from the latest era file.
  let
    (latestEraFile, latestEra) = ?latestEraFile(eraDir)
    f = ?EraFile.open(latestEraFile)
    slot = start_slot(latestEra)
  var bytes: seq[byte]

  ?f.getStateSSZ(slot, bytes)

  if bytes.len() == 0:
    return err("State not found")

  let state =
    try:
      newClone(readSszForkedHashedBeaconState(cfg, slot, bytes))
    except SerializationError as exc:
      return err("Unable to read state: " & exc.msg)

  return ok((state[].historical_summaries(), state[].slot))

proc getBlockProofCapella(
    dataDir: string, eraDir: string, slotNumber: uint64
): (BlockProofHistoricalSummaries, uint64, Hash32) =
  ## Get a beacon block proof for a block from Capella. Also
  ## exports the historical summaries in SSZ encoding as this is required to
  ## verify the proof.
  let
    networkData = loadNetworkData("mainnet")
    db =
      EraDB.new(networkData.metadata.cfg, eraDir, networkData.genesis_validators_root)
    slot = Slot(slotNumber)
    era = era(slot)
    historical_roots = loadHistoricalRoots().asSeq()
    # Note: This could be considered somewhat of a hack. The EraDB API requires
    # access to the historical_summaries, which we do not have. It could be taken
    # from a full node through the rest API, but that is a bit slow as it needs
    # to request the full state. Instead we take the historical summaries from
    # the state in latest era file.
    (historical_summaries, historicalSummariesSlot) = loadHistoricalSummariesFromEra(
      eraDir, networkData.metadata.cfg
    ).valueOr:
      error "Failed to load historical summaries", error
      quit QuitFailure

  var state: ForkedHashedBeaconState

  db.getState(
    historical_roots, historical_summaries.asSeq(), start_slot(era + 1), state
  ).isOkOr:
    error "Failed to load state", error = error
    quit QuitFailure

  let
    beaconBlock = db.getBlock(
      historical_roots,
      historical_summaries.asSeq(),
      slot,
      Opt.none(Eth2Digest),
      capella.TrustedSignedBeaconBlock,
    ).valueOr:
      error "Failed to load Capella block", slot
      quit QuitFailure

    blockRoots = state.block_roots.data
    blockProof = block_proof_historical_summaries.buildProof(
      blockRoots, beaconBlock.message
    ).valueOr:
      error "Failed to build proof for Bellatrix block", slot, error
      quit QuitFailure

    blockNumber = beaconBlock.message.body.execution_payload.block_number
    blockHash = beaconBlock.message.body.execution_payload.block_hash.to(Hash32)

  # Writing the historical_summaries of last state (according to era files)
  # to a file as it is needed for verifying the proof.
  let hsFileName =
    dataDir / "historical_summaries_at_slot_" & $historicalSummariesSlot & ".ssz"
  writeToFile(hsFileName, SSZ.encode(historical_summaries))

  # Writing block.ssz and block_roots.ssz to be able to regenerate this proof
  let blockFileName = dataDir / "block_at_slot_" & $blockProof.slot & ".ssz"
  writeToFile(blockFileName, SSZ.encode(beaconBlock.message))

  let blockRootsFileName = dataDir / "block_roots_at_slot_" & $blockProof.slot & ".ssz"
  withState(state):
    writeToFile(blockRootsFileName, SSZ.encode(blockRoots))

  (blockProof, blockNumber, blockHash)

proc getBlockProofDeneb(
    dataDir: string, eraDir: string, slotNumber: uint64
): (BlockProofHistoricalSummariesDeneb, uint64, Hash32) =
  ## Get a beacon block proof for a block from Deneb and onwards. Also
  ## exports the historical summaries in SSZ encoding as this is required to
  ## verify the proof.
  let
    networkData = loadNetworkData("mainnet")
    db =
      EraDB.new(networkData.metadata.cfg, eraDir, networkData.genesis_validators_root)
    slot = Slot(slotNumber)
    era = era(slot)
    historical_roots = loadHistoricalRoots().asSeq()
    (historical_summaries, historicalSummariesSlot) = loadHistoricalSummariesFromEra(
      eraDir, networkData.metadata.cfg
    ).valueOr:
      error "Failed to load historical summaries", error
      quit QuitFailure

  var state: ForkedHashedBeaconState

  db.getState(
    historical_roots, historical_summaries.asSeq(), start_slot(era + 1), state
  ).isOkOr:
    error "Failed to load state", error = error
    quit QuitFailure

  let
    beaconBlock = db.getBlock(
      historical_roots,
      historical_summaries.asSeq(),
      slot,
      Opt.none(Eth2Digest),
      deneb.TrustedSignedBeaconBlock,
    ).valueOr:
      error "Failed to load Capella block", slot
      quit QuitFailure

    blockRoots = state.block_roots.data
    blockProof = block_proof_historical_summaries.buildProof(
      blockRoots, beaconBlock.message
    ).valueOr:
      error "Failed to build proof for Bellatrix block", slot, error
      quit QuitFailure

    blockNumber = beaconBlock.message.body.execution_payload.block_number
    blockHash = beaconBlock.message.body.execution_payload.block_hash.to(Hash32)

  # Writing the historical_summaries of last state (according to era files)
  # to a file as it is needed for verifying the proof.
  let hsFileName =
    dataDir / "historical_summaries_at_slot_" & $historicalSummariesSlot & ".ssz"
  writeToFile(hsFileName, SSZ.encode(historical_summaries))

  # Writing block.ssz and block_roots.ssz to be able to regenerate this proof
  let blockFileName = dataDir / "block_at_slot_" & $blockProof.slot & ".ssz"
  writeToFile(blockFileName, SSZ.encode(beaconBlock.message))

  let blockRootsFileName = dataDir / "block_roots_at_slot_" & $blockProof.slot & ".ssz"
  withState(state):
    writeToFile(blockRootsFileName, SSZ.encode(blockRoots))

  (blockProof, blockNumber, blockHash)

proc exportBlockProof*(dataDir: string, eraDir: string, slotNumber: uint64) =
  let
    networkData = loadNetworkData("mainnet")
    cfg = networkData.metadata.cfg
    slot = Slot(slotNumber)

  if slot.epoch() >= cfg.DENEB_FORK_EPOCH:
    let (proof, blockNumber, blockHash) =
      getBlockProofDeneb(dataDir, eraDir, slotNumber)

    let yamlTestProof = YamlTestProofDeneb(
      execution_block_header: blockHash.to0xHex(),
      execution_block_proof: proof.executionBlockProof.toHex(array[12, string]),
      beacon_block_root: proof.beaconBlockRoot.data.to0xHex(),
      beacon_block_proof: proof.beaconBlockProof.toHex(array[13, string]),
      slot: proof.slot.uint64,
    )

    let file = dataDir / "beacon_block_proof-" & $blockNumber & ".yaml"
    yamlTestProof.writeDataToYaml(file)
  elif slot.epoch() >= cfg.CAPELLA_FORK_EPOCH:
    let (proof, blockNumber, blockHash) =
      getBlockProofCapella(dataDir, eraDir, slotNumber)

    let yamlTestProof = YamlTestProofCapella(
      execution_block_header: blockHash.to0xHex(),
      execution_block_proof: proof.executionBlockProof.toHex(array[11, string]),
      beacon_block_root: proof.beaconBlockRoot.data.to0xHex(),
      beacon_block_proof: proof.beaconBlockProof.toHex(array[13, string]),
      slot: proof.slot.uint64,
    )

    let file = dataDir / "beacon_block_proof-" & $blockNumber & ".yaml"
    yamlTestProof.writeDataToYaml(file)
  elif slot.epoch() >= cfg.BELLATRIX_FORK_EPOCH:
    let (proof, blockNumber, blockHash) =
      getBlockProofBellatrix(dataDir, eraDir, slotNumber)

    let yamlTestProof = YamlTestProofBellatrix(
      execution_block_header: blockHash.to0xHex(),
      execution_block_proof: proof.executionBlockProof.toHex(array[11, string]),
      beacon_block_root: proof.beaconBlockRoot.data.to0xHex(),
      beacon_block_proof: proof.beaconBlockProof.toHex(array[14, string]),
      slot: proof.slot.uint64,
    )

    let file = dataDir / "beacon_block_proof-" & $blockNumber & ".yaml"
    yamlTestProof.writeDataToYaml(file)
  else:
    error "Slot number is before Bellatrix fork", slotNumber
    quit QuitFailure
