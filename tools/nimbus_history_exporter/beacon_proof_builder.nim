# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

##
## Builds post-merge block proofs (BlockProofHistoricalRoots,
## BlockProofHistoricalSummaries, BlockProofHistoricalSummariesDeneb)
## using beacon chain era files as the data source.
##

{.push raises: [], gcsafe.}

import
  std/times,
  chronos,
  results,
  ssz_serialization,
  beacon_chain/era_db,
  beacon_chain/networking/[network_metadata, network_metadata_downloads],
  beacon_chain/spec/[forks, eth2_ssz_serialization],
  beacon_chain/beacon_clock,
  ../../portal/eth_history/block_proofs/block_proof_historical_roots,
  ../../portal/eth_history/block_proofs/block_proof_historical_summaries

from ../../portal/eth_history/ere import Proof, init

export results, era_db, network_metadata

type BeaconProofBuilder* = ref object
  db: EraDB
  cfg: RuntimeConfig
  clock: BeaconClock
  historicalRoots: seq[Eth2Digest]
  historicalSummaries: seq[HistoricalSummary]
  # Single-entry state cache: loading a full BeaconState is expensive so we
  # keep the most-recently-used beacon era's state in memory.
  cachedBeaconEra: uint64
  cachedState: ForkedHashedBeaconState
  hasCachedState: bool

proc ensureStateLoaded(b: BeaconProofBuilder, beaconEra: uint64): Result[void, string] =
  if b.hasCachedState and b.cachedBeaconEra == beaconEra:
    return ok()

  let stateSlot = Slot((beaconEra + 1) * SLOTS_PER_HISTORICAL_ROOT)
  b.db.getState(b.historicalRoots, b.historicalSummaries, stateSlot, b.cachedState).isOkOr:
    return err(
      "Cannot load beacon state for era " & $beaconEra & " (slot " & $stateSlot & "): " &
        error
    )
  b.cachedBeaconEra = beaconEra
  b.hasCachedState = true
  ok()

proc loadHistoricalDataFromEraDir*(
    cfg: RuntimeConfig, eraDir: string
): Result[(HistoricalRoots, HistoricalSummaries), string] =
  ## Loads `historical_roots` and `historical_summaries` from the latest era
  ## file in `eraDir`.
  let
    (latestEra, latestPath) = EraFile.latest(cfg, eraDir).valueOr:
      return err("No era files found in " & eraDir)
    latestSlot = start_slot(latestEra)
    eraFile = EraFile.open(latestPath).valueOr:
      return err("Cannot open latest era file " & latestPath & ": " & error)

  var bytes: seq[byte]
  ?eraFile.getStateSSZ(latestSlot, bytes)

  if bytes.len() == 0:
    return err("State not found in era file")

  let state =
    try:
      newClone(readSszForkedHashedBeaconState(cfg, latestSlot, bytes))
    except SerializationError as exc:
      return err("Cannot deserialize state: " & exc.msg)

  withState(state[]):
    when consensusFork >= ConsensusFork.Capella:
      ok((forkyState.data.historical_roots, forkyState.data.historical_summaries))
    else:
      # No historical summaries yet before Capella
      ok((forkyState.data.historical_roots, HistoricalSummaries()))

proc init*(
    _: type BeaconProofBuilder, eraDir: string, networkName: string
): Result[BeaconProofBuilder, string] =
  ## Init a BeaconProofBuilder backed by the era files in `eraDir`.
  ## `historical_roots` and `historical_summaries` are bootstrapped from the
  ## latest era file.
  let
    metadata = getMetadataForNetwork(networkName)
    cfg = metadata.cfg

    (genesisValidatorsRoot, genesisTime) =
      if metadata.genesis.kind == GenesisMetadataKind.BakedIn:
        # Get genesis_validators_root and genesis_time from the baked-in metadata.
        let genesisHeader =
          try:
            SSZ.decode(
              metadata.genesis.bakedBytes.toOpenArray(0, sizeof(BeaconStateHeader) - 1),
              BeaconStateHeader,
            )
          except SerializationError as exc:
            return err("Cannot decode genesis state header: " & exc.msg)
        (genesisHeader.genesis_validators_root, genesisHeader.genesis_time)
      else:
        # For networks where genesis is not baked in (e.g. hoodi), download it.
        let genesisState =
          try:
            waitFor fetchGenesisState(metadata)
          except CatchableError as exc:
            return err("Failed to fetch genesis state: " & exc.msg)
        withState(genesisState[]):
          (forkyState.data.genesis_validators_root, forkyState.data.genesis_time)

    clock = BeaconClock.init(cfg.timeParams, genesisTime).valueOr:
      return err("Invalid genesis time in genesis state")
    (roots, summaries) = ?loadHistoricalDataFromEraDir(cfg, eraDir)
    db = EraDB.new(cfg, eraDir, genesisValidatorsRoot)

  ok(
    BeaconProofBuilder(
      db: db,
      cfg: cfg,
      clock: clock,
      historicalRoots: roots.asSeq(),
      historicalSummaries: summaries.asSeq(),
    )
  )

proc buildProof*(b: BeaconProofBuilder, timestamp: uint64): Result[Proof, string] =
  ## Build a post-merge block proof for the EL block with the given timestamp.
  ## Returns a Proof with the proof type set and SSZ-encoded proof data.
  let (afterGenesis, tsSlot) = b.clock.toSlot(times.fromUnix(timestamp.int64))

  # On PoS-only networks (e.g. hoodi), GENESIS_DELAY > 0 means the EL
  # genesis block's timestamp predates the CL genesis time. The genesis beacon
  # block at slot 0 holds the genesis EL payload, so we use slot 0.
  let slot =
    if afterGenesis:
      tsSlot
    else:
      Slot(0)

  let beaconEra = slot.uint64 div SLOTS_PER_HISTORICAL_ROOT
  ?b.ensureStateLoaded(beaconEra)

  let epoch = slot.epoch()
  if epoch >= b.cfg.GLOAS_FORK_EPOCH:
    # Gloas removed the execution payload from the BeaconBlockBody
    err("Gloas fork and later not yet supported for proof building")
  elif epoch >= b.cfg.DENEB_FORK_EPOCH:
    let
      blck = b.db.getBlock(
        b.historicalRoots,
        b.historicalSummaries,
        slot,
        Opt.none(Eth2Digest),
        deneb.TrustedSignedBeaconBlock,
      ).valueOr:
        return err("No Deneb beacon block found at slot " & $slot)

      proof = ?block_proof_historical_summaries.buildProof(
        b.cachedState.block_roots.data, blck.message
      )

    ok(Proof.init(proof))
  elif epoch >= b.cfg.CAPELLA_FORK_EPOCH:
    let
      blck = b.db.getBlock(
        b.historicalRoots,
        b.historicalSummaries,
        slot,
        Opt.none(Eth2Digest),
        capella.TrustedSignedBeaconBlock,
      ).valueOr:
        return err("No Capella beacon block found at slot " & $slot)

      proof = ?block_proof_historical_summaries.buildProof(
        b.cachedState.block_roots.data, blck.message
      )

    ok(Proof.init(proof))
  elif epoch >= b.cfg.BELLATRIX_FORK_EPOCH:
    let
      blck = b.db.getBlock(
        b.historicalRoots,
        b.historicalSummaries,
        slot,
        Opt.none(Eth2Digest),
        bellatrix.TrustedSignedBeaconBlock,
      ).valueOr:
        return err("No Bellatrix beacon block found at slot " & $slot)

      batch = HistoricalBatch(
        block_roots: b.cachedState.block_roots.data,
        state_roots: b.cachedState.state_roots.data,
      )
      proof = ?block_proof_historical_roots.buildProof(batch, blck.message)

    ok(Proof.init(proof))
  else:
    err(
      "Slot " & $slot & " in epoch " & $epoch & " is pre-Bellatrix, no execution payload"
    )
