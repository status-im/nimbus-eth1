# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, atomics],
  beacon_chain/nimbus_binary_common,
  beacon_chain/spec/forks,
  beacon_chain/[beacon_chain_db, trusted_node_sync],
  beacon_chain/networking/network_metadata_downloads,
  chronos,
  chronicles,
  stew/io2,
  ../configs/nimbus_configs

export nimbus_configs

## log
logScope:
  topics = "Consensus layer"

## following procedures are copies from nimbus_beacon_node.nim.
## TODO: if possible, extract from that file into a common file

## runs beacon node
## adapted from nimbus-eth2
proc doRunBeaconNode(
    config: var BeaconNodeConf, rng: ref HmacDrbgContext
) {.raises: [CatchableError].} =
  info "Launching beacon node",
    version = "fullVersionStr", #TODO:changed from original version
    bls_backend = $BLS_BACKEND,
    const_preset,
    cmdParams = commandLineParams(),
    config

  template ignoreDeprecatedOption(option: untyped): untyped =
    if config.option.isSome:
      warn "Config option is deprecated", option = config.option.get

  ignoreDeprecatedOption requireEngineAPI
  ignoreDeprecatedOption safeSlotsToImportOptimistically
  ignoreDeprecatedOption terminalTotalDifficultyOverride
  ignoreDeprecatedOption optimistic
  ignoreDeprecatedOption validatorMonitorTotals
  ignoreDeprecatedOption web3ForcePolling

  config.createDumpDirs()

  #TODO: We might need to split this on the same file
  # if config.metricsEnabled:
  #   let metricsAddress = config.metricsAddress
  #   notice "Starting metrics HTTP server",
  #     url = "http://" & $metricsAddress & ":" & $config.metricsPort & "/metrics"
  #   try:
  #     startMetricsHttpServer($metricsAddress, config.metricsPort)
  #   except CatchableError as exc:
  #     raise exc
  #   except Exception as exc:
  #     raiseAssert exc.msg # TODO fix metrics

## adapted/copied from nimbus-eth2
proc fetchGenesisState(
    metadata: Eth2NetworkMetadata,
    genesisState = none(InputFile),
    genesisStateUrl = none(Uri),
): Future[ref ForkedHashedBeaconState] {.async: (raises: []).} =
  let genesisBytes =
    if metadata.genesis.kind != BakedIn and genesisState.isSome:
      let res = io2.readAllBytes(genesisState.get.string)
      res.valueOr:
        error "Failed to read genesis state file", err = res.error.ioErrorMsg
        quit 1
    elif metadata.hasGenesis:
      try:
        if metadata.genesis.kind == BakedInUrl:
          info "Obtaining genesis state",
            sourceUrl = $genesisStateUrl.get(parseUri metadata.genesis.url)
        await metadata.fetchGenesisBytes(genesisStateUrl)
      except CatchableError as err:
        error "Failed to obtain genesis state",
          source = metadata.genesis.sourceDesc, err = err.msg
        quit 1
    else:
      @[]

  if genesisBytes.len > 0:
    try:
      newClone readSszForkedHashedBeaconState(metadata.cfg, genesisBytes)
    except CatchableError as err:
      error "Invalid genesis state",
        size = genesisBytes.len, digest = eth2digest(genesisBytes), err = err.msg
      quit 1
  else:
    nil

## adapted/copied from nimbus-eth2
proc doRunTrustedNodeSync(
    db: BeaconChainDB,
    metadata: Eth2NetworkMetadata,
    databaseDir: string,
    eraDir: string,
    restUrl: string,
    stateId: Option[string],
    trustedBlockRoot: Option[Eth2Digest],
    backfill: bool,
    reindex: bool,
    downloadDepositSnapshot: bool,
    genesisState: ref ForkedHashedBeaconState,
) {.async.} =
  let syncTarget =
    if stateId.isSome:
      if trustedBlockRoot.isSome:
        warn "Ignoring `trustedBlockRoot`, `stateId` is set", stateId, trustedBlockRoot
      TrustedNodeSyncTarget(kind: TrustedNodeSyncKind.StateId, stateId: stateId.get)
    elif trustedBlockRoot.isSome:
      TrustedNodeSyncTarget(
        kind: TrustedNodeSyncKind.TrustedBlockRoot,
        trustedBlockRoot: trustedBlockRoot.get,
      )
    else:
      TrustedNodeSyncTarget(kind: TrustedNodeSyncKind.StateId, stateId: "finalized")

  await db.doTrustedNodeSync(
    metadata.cfg, databaseDir, eraDir, restUrl, syncTarget, backfill, reindex,
    downloadDepositSnapshot, genesisState,
  )

## --end copy paste file from nimbus-eth2/nimbus_beacon_node.nim

## Consensus wrapper
proc consensusWrapper*(parameters: TaskParameters) {.raises: [CatchableError].} =
  # Single RNG instance for the application - will be seeded on construction
  # and avoid using system resources (such as urandom) after that
  let rng = HmacDrbgContext.new()
  var config = parameters.beaconNodeConfigs

  setupFileLimits()

  #TODO: Another FC unsafe procedure
  # setupLogging(config.logLevel, config.logStdout, config.logFile)

  try:
    doRunBeaconNode(config, rng)
  except CatchableError as e:
    fatal "error", message = e.msg

  isShutDownRequired.store(true)
  warn "\tExiting consensus wrapper"