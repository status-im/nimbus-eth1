# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#TODO: Clean these imports
import
  std/[os, atomics, random, terminal, times, exitprocs, sequtils],
  metrics,
  beacon_chain/nimbus_binary_common,
  beacon_chain/spec/forks,
  beacon_chain/[beacon_chain_db, trusted_node_sync],
  beacon_chain/networking/network_metadata_downloads,
  chronos,
  chronicles,
  stew/io2,
  eth/p2p/discoveryv5/[enr, random2],
  ../configs/nimbus_configs,
  beacon_chain/consensus_object_pools/vanity_logs/vanity_logs,
  beacon_chain/statusbar,
  beacon_chain/nimbus_binary_common,
  beacon_chain/spec/[forks, digest, helpers],
  beacon_chain/spec/datatypes/base,
  beacon_chain/[beacon_chain_db, trusted_node_sync, beacon_node],
  beacon_chain/spec/weak_subjectivity,
  beacon_chain/rpc/[rest_beacon_api, rest_api, state_ttl_cache],
  beacon_chain/consensus_object_pools/blob_quarantine,
  beacon_chain/networking/[topic_params, network_metadata, network_metadata_downloads],
  beacon_chain/spec/datatypes/[bellatrix],
  beacon_chain/sync/[sync_protocol],
  beacon_chain/validators/[keystore_management, beacon_validators],
  beacon_chain/consensus_object_pools/[blockchain_dag],
  beacon_chain/spec/
    [beaconstate, state_transition, state_transition_epoch, validator, ssz_codec]

export nimbus_configs

when defined(posix):
  import system/ansi_c

from beacon_chain/spec/datatypes/deneb import SignedBeaconBlock
from beacon_chain/beacon_node_light_client import
  shouldSyncOptimistically, initLightClient, updateLightClientFromDag
from libp2p/protocols/pubsub/gossipsub import TopicParams, validateParameters, init

## log
logScope:
  topics = "Consensus layer"

# adapted from nimbus-eth2
# # https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#interop-metrics
# declareGauge beacon_slot, "Latest slot of the beacon chain state"
# declareGauge beacon_current_epoch, "Current epoch"

# # Finalization tracking
# declareGauge finalization_delay,
#   "Epoch delay between scheduled epoch and finalized epoch"

# declareGauge ticks_delay,
#   "How long does to take to run the onSecond loop"

# declareGauge next_action_wait,
#   "Seconds until the next attestation will be sent"

# declareGauge next_proposal_wait,
#   "Seconds until the next proposal will be sent, or Inf if not known"

# declareGauge sync_committee_active,
#   "1 if there are current sync committee duties, 0 otherwise"

# declareCounter db_checkpoint_seconds,
#   "Time spent checkpointing the database to clear the WAL file"

const SlashingDbName = "slashing_protection"
# changing this requires physical file rename as well or history is lost

## NOTE
## following procedures are copies/adaptations from nimbus_beacon_node.nim.
## TODO: Extract do adequate structures and files

# TODO: need to figure out behaviour on threaded patterns
# Using this function here is signaled as non GC SAFE given
#  that gPidFile might be accessed concurrently with no guards

# var gPidFile: string
# proc createPidFile(filename: string) {.raises: [IOError].} =
#   writeFile filename, $os.getCurrentProcessId()
#   gPidFile = filename
#   addExitProc (
#     proc() =
#       discard io2.removeFile(filename)
#   )

proc initFullNode(
    node: BeaconNode,
    rng: ref HmacDrbgContext,
    dag: ChainDAGRef,
    taskpool: TaskPoolPtr,
    getBeaconTime: GetBeaconTimeFn,
) {.async.} =
  template config(): auto =
    node.config

  proc onPhase0AttestationReceived(data: phase0.Attestation) =
    node.eventBus.attestQueue.emit(data)

  proc onElectraAttestationReceived(data: electra.Attestation) =
    debugComment "electra attestation queue"

  proc onSyncContribution(data: SignedContributionAndProof) =
    node.eventBus.contribQueue.emit(data)

  proc onVoluntaryExitAdded(data: SignedVoluntaryExit) =
    node.eventBus.exitQueue.emit(data)

  proc onBLSToExecutionChangeAdded(data: SignedBLSToExecutionChange) =
    node.eventBus.blsToExecQueue.emit(data)

  proc onProposerSlashingAdded(data: ProposerSlashing) =
    node.eventBus.propSlashQueue.emit(data)

  proc onPhase0AttesterSlashingAdded(data: phase0.AttesterSlashing) =
    node.eventBus.attSlashQueue.emit(data)

  proc onElectraAttesterSlashingAdded(data: electra.AttesterSlashing) =
    debugComment "electra att slasher queue"

  proc onBlobSidecarAdded(data: BlobSidecarInfoObject) =
    node.eventBus.blobSidecarQueue.emit(data)

  proc onBlockAdded(data: ForkedTrustedSignedBeaconBlock) =
    let optimistic =
      if node.currentSlot().epoch() >= dag.cfg.BELLATRIX_FORK_EPOCH:
        some node.dag.is_optimistic(data.toBlockId())
      else:
        none[bool]()
    node.eventBus.blocksQueue.emit(EventBeaconBlockObject.init(data, optimistic))

  proc onHeadChanged(data: HeadChangeInfoObject) =
    let eventData =
      if node.currentSlot().epoch() >= dag.cfg.BELLATRIX_FORK_EPOCH:
        var res = data
        res.optimistic =
          some node.dag.is_optimistic(BlockId(slot: data.slot, root: data.block_root))
        res
      else:
        data
    node.eventBus.headQueue.emit(eventData)

  proc onChainReorg(data: ReorgInfoObject) =
    let eventData =
      if node.currentSlot().epoch() >= dag.cfg.BELLATRIX_FORK_EPOCH:
        var res = data
        res.optimistic = some node.dag.is_optimistic(
          BlockId(slot: data.slot, root: data.new_head_block)
        )
        res
      else:
        data
    node.eventBus.reorgQueue.emit(eventData)

  proc makeOnFinalizationCb(
      # This `nimcall` functions helps for keeping track of what
      # needs to be captured by the onFinalization closure.
      eventBus: EventBus,
      elManager: ELManager,
  ): OnFinalizedCallback {.nimcall.} =
    static:
      doAssert (elManager is ref)
    return proc(dag: ChainDAGRef, data: FinalizationInfoObject) =
      if elManager != nil:
        let finalizedEpochRef = dag.getFinalizedEpochRef()
        discard trackFinalizedState(
          elManager, finalizedEpochRef.eth1_data, finalizedEpochRef.eth1_deposit_index
        )
      # node.updateLightClientFromDag()
      let eventData =
        if node.currentSlot().epoch() >= dag.cfg.BELLATRIX_FORK_EPOCH:
          var res = data
          # `slot` in this `BlockId` may be higher than block's actual slot,
          # this is alright for the purpose of calling `is_optimistic`.
          res.optimistic = some node.dag.is_optimistic(
            BlockId(slot: data.epoch.start_slot, root: data.block_root)
          )
          res
        else:
          data
      eventBus.finalQueue.emit(eventData)

  func getLocalHeadSlot(): Slot =
    dag.head.slot

  proc getLocalWallSlot(): Slot =
    node.beaconClock.now.slotOrZero

  func getFirstSlotAtFinalizedEpoch(): Slot =
    dag.finalizedHead.slot

  func getBackfillSlot(): Slot =
    if dag.backfill.parent_root != dag.tail.root: dag.backfill.slot else: dag.tail.slot

  func getFrontfillSlot(): Slot =
    max(dag.frontfill.get(BlockId()).slot, dag.horizon)

  proc isWithinWeakSubjectivityPeriod(): bool =
    let
      currentSlot = node.beaconClock.now().slotOrZero()
      checkpoint = Checkpoint(
        epoch: epoch(getStateField(node.dag.headState, slot)),
        root: getStateField(node.dag.headState, latest_block_header).state_root,
      )
    is_within_weak_subjectivity_period(
      node.dag.cfg, currentSlot, node.dag.headState, checkpoint
    )

  proc eventWaiter(): Future[void] {.async: (raises: [CancelledError]).} =
    await node.shutdownEvent.wait()
    bnStatus = BeaconNodeStatus.Stopping

  asyncSpawn eventWaiter()

  let
    quarantine = newClone(Quarantine.init())
    attestationPool = newClone(
      AttestationPool.init(
        dag, quarantine, onPhase0AttestationReceived, onElectraAttestationReceived
      )
    )
    syncCommitteeMsgPool =
      newClone(SyncCommitteeMsgPool.init(rng, dag.cfg, onSyncContribution))
    # adapted from nimbus-eth2
    # lightClientPool = newClone(LightClientPool())
    validatorChangePool = newClone(
      ValidatorChangePool.init(
        dag, attestationPool, onVoluntaryExitAdded, onBLSToExecutionChangeAdded,
        onProposerSlashingAdded, onPhase0AttesterSlashingAdded,
        onElectraAttesterSlashingAdded,
      )
    )
    blobQuarantine = newClone(BlobQuarantine.init(onBlobSidecarAdded))
    consensusManager = ConsensusManager.new(
      dag,
      attestationPool,
      quarantine,
      node.elManager,
      ActionTracker.init(node.network.nodeId, config.subscribeAllSubnets),
      node.dynamicFeeRecipientsStore,
      config.validatorsDir,
      config.defaultFeeRecipient,
      config.suggestedGasLimit,
    )
    blockProcessor = BlockProcessor.new(
      config.dumpEnabled, config.dumpDirInvalid, config.dumpDirIncoming, rng, taskpool,
      consensusManager, node.validatorMonitor, blobQuarantine, getBeaconTime,
    )
    blockVerifier = proc(
        signedBlock: ForkedSignedBeaconBlock,
        blobs: Opt[BlobSidecars],
        maybeFinalized: bool,
    ): Future[Result[void, VerifierError]] {.
        async: (raises: [CancelledError], raw: true)
    .} =
      # The design with a callback for block verification is unusual compared
      # to the rest of the application, but fits with the general approach
      # taken in the sync/request managers - this is an architectural compromise
      # that should probably be reimagined more holistically in the future.
      blockProcessor[].addBlock(
        MsgSource.gossip, signedBlock, blobs, maybeFinalized = maybeFinalized
      )
    rmanBlockVerifier = proc(
        signedBlock: ForkedSignedBeaconBlock, maybeFinalized: bool
    ): Future[Result[void, VerifierError]] {.async: (raises: [CancelledError]).} =
      withBlck(signedBlock):
        when consensusFork >= ConsensusFork.Deneb:
          if not blobQuarantine[].hasBlobs(forkyBlck):
            # We don't have all the blobs for this block, so we have
            # to put it in blobless quarantine.
            if not quarantine[].addBlobless(dag.finalizedHead.slot, forkyBlck):
              err(VerifierError.UnviableFork)
            else:
              err(VerifierError.MissingParent)
          else:
            let blobs = blobQuarantine[].popBlobs(forkyBlck.root, forkyBlck)
            await blockProcessor[].addBlock(
              MsgSource.gossip,
              signedBlock,
              Opt.some(blobs),
              maybeFinalized = maybeFinalized,
            )
        else:
          await blockProcessor[].addBlock(
            MsgSource.gossip,
            signedBlock,
            Opt.none(BlobSidecars),
            maybeFinalized = maybeFinalized,
          )
    rmanBlockLoader = proc(blockRoot: Eth2Digest): Opt[ForkedTrustedSignedBeaconBlock] =
      dag.getForkedBlock(blockRoot)
    rmanBlobLoader = proc(blobId: BlobIdentifier): Opt[ref BlobSidecar] =
      var blob_sidecar = BlobSidecar.new()
      if dag.db.getBlobSidecar(blobId.block_root, blobId.index, blob_sidecar[]):
        Opt.some blob_sidecar
      else:
        Opt.none(ref BlobSidecar)

    #TODO:
    # removing this light client var
    lightClientPool = newClone(LightClientPool())

    processor = Eth2Processor.new(
      config.doppelgangerDetection, blockProcessor, node.validatorMonitor, dag,
      attestationPool, validatorChangePool, node.attachedValidators,
      syncCommitteeMsgPool, lightClientPool, quarantine, blobQuarantine, rng,
      getBeaconTime, taskpool,
    )
    syncManagerFlags =
      if node.config.longRangeSync != LongRangeSyncMode.Lenient:
        {SyncManagerFlag.NoGenesisSync}
      else:
        {}
    syncManager = newSyncManager[Peer, PeerId](
      node.network.peerPool,
      dag.cfg.DENEB_FORK_EPOCH,
      dag.cfg.MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS,
      SyncQueueKind.Forward,
      getLocalHeadSlot,
      getLocalWallSlot,
      getFirstSlotAtFinalizedEpoch,
      getBackfillSlot,
      getFrontfillSlot,
      isWithinWeakSubjectivityPeriod,
      dag.tail.slot,
      blockVerifier,
      shutdownEvent = node.shutdownEvent,
      flags = syncManagerFlags,
    )
    backfiller = newSyncManager[Peer, PeerId](
      node.network.peerPool,
      dag.cfg.DENEB_FORK_EPOCH,
      dag.cfg.MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS,
      SyncQueueKind.Backward,
      getLocalHeadSlot,
      getLocalWallSlot,
      getFirstSlotAtFinalizedEpoch,
      getBackfillSlot,
      getFrontfillSlot,
      isWithinWeakSubjectivityPeriod,
      dag.backfill.slot,
      blockVerifier,
      maxHeadAge = 0,
      shutdownEvent = node.shutdownEvent,
      flags = syncManagerFlags,
    )
    router = (ref MessageRouter)(processor: processor, network: node.network)
    requestManager = RequestManager.init(
      node.network,
      dag.cfg.DENEB_FORK_EPOCH,
      getBeaconTime,
      (
        proc(): bool =
          syncManager.inProgress
      ),
      quarantine,
      blobQuarantine,
      rmanBlockVerifier,
      rmanBlockLoader,
      rmanBlobLoader,
    )
  # adapted from nimbus-eth2
  # if node.config.lightClientDataServe:
  #   proc scheduleSendingLightClientUpdates(slot: Slot) =
  #     if node.lightClientPool[].broadcastGossipFut != nil:
  #       return
  #     if slot <= node.lightClientPool[].latestBroadcastedSlot:
  #       return
  #     node.lightClientPool[].latestBroadcastedSlot = slot

  #     template fut(): auto =
  #       node.lightClientPool[].broadcastGossipFut

  #     fut = node.handleLightClientUpdates(slot)
  #     fut.addCallback do(p: pointer) {.gcsafe.}:
  #       fut = nil

  #   router.onSyncCommitteeMessage = scheduleSendingLightClientUpdates

  dag.setFinalizationCb makeOnFinalizationCb(node.eventBus, node.elManager)
  dag.setBlockCb(onBlockAdded)
  dag.setHeadCb(onHeadChanged)
  dag.setReorgCb(onChainReorg)

  node.dag = dag
  node.blobQuarantine = blobQuarantine
  node.quarantine = quarantine
  node.attestationPool = attestationPool
  node.syncCommitteeMsgPool = syncCommitteeMsgPool
  # node.lightClientPool = lightClientPool
  node.validatorChangePool = validatorChangePool
  node.processor = processor
  node.blockProcessor = blockProcessor
  node.consensusManager = consensusManager
  node.requestManager = requestManager
  node.syncManager = syncManager
  node.backfiller = backfiller
  node.router = router

  await node.addValidators()

  block:
    # Add in-process validators to the list of "known" validators such that
    # we start with a reasonable ENR
    let wallSlot = node.beaconClock.now().slotOrZero()
    for validator in node.attachedValidators[].validators.values():
      if config.validatorMonitorAuto:
        node.validatorMonitor[].addMonitor(validator.pubkey, validator.index)

      if validator.index.isSome():
        withState(dag.headState):
          let idx = validator.index.get()
          if distinctBase(idx) <= forkyState.data.validators.lenu64:
            template v(): auto =
              forkyState.data.validators.item(idx)

            if is_active_validator(v, wallSlot.epoch) or
                is_active_validator(v, wallSlot.epoch + 1):
              node.consensusManager[].actionTracker.knownValidators[idx] = wallSlot
            elif is_exited_validator(v, wallSlot.epoch):
              notice "Ignoring exited validator",
                index = idx, pubkey = shortLog(v.pubkey)
    let stabilitySubnets =
      node.consensusManager[].actionTracker.stabilitySubnets(wallSlot)
    # Here, we also set the correct ENR should we be in all subnets mode!
    node.network.updateStabilitySubnetMetadata(stabilitySubnets)

  node.network.registerProtocol(
    PeerSync, PeerSync.NetworkState.init(node.dag, node.beaconClock.getBeaconTimeFn())
  )

  node.network.registerProtocol(BeaconSync, BeaconSync.NetworkState.init(node.dag))
  # adapted from nimbus-eth2

  # if node.dag.lcDataStore.serve:
  #   node.network.registerProtocol(
  #     LightClientSync, LightClientSync.NetworkState.init(node.dag)
  #   )

  # node.updateValidatorMetrics()

func getVanityLogs(stdoutKind: StdoutLogKind): VanityLogs =
  case stdoutKind
  of StdoutLogKind.Auto:
    raiseAssert "inadmissable here"
  of StdoutLogKind.Colors:
    VanityLogs(
      onMergeTransitionBlock: bellatrixColor,
      onFinalizedMergeTransitionBlock: bellatrixBlink,
      onUpgradeToCapella: capellaColor,
      onKnownBlsToExecutionChange: capellaBlink,
      onUpgradeToDeneb: denebColor,
      onUpgradeToElectra: electraColor,
    )
  of StdoutLogKind.NoColors:
    VanityLogs(
      onMergeTransitionBlock: bellatrixMono,
      onFinalizedMergeTransitionBlock: bellatrixMono,
      onUpgradeToCapella: capellaMono,
      onKnownBlsToExecutionChange: capellaMono,
      onUpgradeToDeneb: denebMono,
      onUpgradeToElectra: electraMono,
    )
  of StdoutLogKind.Json, StdoutLogKind.None:
    VanityLogs(
      onMergeTransitionBlock: (
        proc() =
          notice "🐼 Proof of Stake Activated 🐼"
      ),
      onFinalizedMergeTransitionBlock: (
        proc() =
          notice "🐼 Proof of Stake Finalized 🐼"
      ),
      onUpgradeToCapella: (
        proc() =
          notice "🦉 Withdrowls now available 🦉"
      ),
      onKnownBlsToExecutionChange: (
        proc() =
          notice "🦉 BLS to execution changed 🦉"
      ),
      onUpgradeToDeneb: (
        proc() =
          notice "🐟 Proto-Danksharding is ON 🐟"
      ),
      onUpgradeToElectra: (
        proc() =
          notice "🦒 [PH] Electra 🦒"
      ),
    )

func getVanityMascot(consensusFork: ConsensusFork): string =
  case consensusFork
  of ConsensusFork.Electra: "🦒"
  of ConsensusFork.Deneb: "🐟"
  of ConsensusFork.Capella: "🦉"
  of ConsensusFork.Bellatrix: "🐼"
  of ConsensusFork.Altair: "✨"
  of ConsensusFork.Phase0: "🦏"

# NOTE: light client related code commented
proc loadChainDag(
    config: BeaconNodeConf,
    cfg: RuntimeConfig,
    db: BeaconChainDB,
    eventBus: EventBus,
    validatorMonitor: ref ValidatorMonitor,
    networkGenesisValidatorsRoot: Opt[Eth2Digest],
): ChainDAGRef =
  info "Loading block DAG from database", path = config.databaseDir

  var dag: ChainDAGRef
  proc onLightClientFinalityUpdate(data: ForkedLightClientFinalityUpdate) =
    if dag == nil:
      return
    withForkyFinalityUpdate(data):
      when lcDataFork > LightClientDataFork.None:
        let contextFork = dag.cfg.consensusForkAtEpoch(forkyFinalityUpdate.contextEpoch)
        eventBus.finUpdateQueue.emit(
          RestVersioned[ForkedLightClientFinalityUpdate](
            data: data,
            jsonVersion: contextFork,
            sszContext: dag.forkDigests[].atConsensusFork(contextFork),
          )
        )

  proc onLightClientOptimisticUpdate(data: ForkedLightClientOptimisticUpdate) =
    if dag == nil:
      return
    withForkyOptimisticUpdate(data):
      when lcDataFork > LightClientDataFork.None:
        let contextFork =
          dag.cfg.consensusForkAtEpoch(forkyOptimisticUpdate.contextEpoch)
        eventBus.optUpdateQueue.emit(
          RestVersioned[ForkedLightClientOptimisticUpdate](
            data: data,
            jsonVersion: contextFork,
            sszContext: dag.forkDigests[].atConsensusFork(contextFork),
          )
        )

  let
    chainDagFlags =
      if config.strictVerification:
        {strictVerification}
      else:
        {}
    onLightClientFinalityUpdateCb =
      if config.lightClientDataServe: onLightClientFinalityUpdate else: nil
    onLightClientOptimisticUpdateCb =
      if config.lightClientDataServe: onLightClientOptimisticUpdate else: nil

  dag = ChainDAGRef.init(
    cfg,
    db,
    validatorMonitor,
    chainDagFlags,
    config.eraDir,
    vanityLogs = getVanityLogs(detectTTY(config.logStdout)),
    lcDataConfig = LightClientDataConfig(
      serve: config.lightClientDataServe,
      importMode: config.lightClientDataImportMode,
      maxPeriods: config.lightClientDataMaxPeriods,
      onLightClientFinalityUpdate: onLightClientFinalityUpdateCb,
      onLightClientOptimisticUpdate: onLightClientOptimisticUpdateCb,
    ),
  )

  if networkGenesisValidatorsRoot.isSome:
    let databaseGenesisValidatorsRoot =
      getStateField(dag.headState, genesis_validators_root)
    if networkGenesisValidatorsRoot.get != databaseGenesisValidatorsRoot:
      fatal "The specified --data-dir contains data for a different network",
        networkGenesisValidatorsRoot = networkGenesisValidatorsRoot.get,
        databaseGenesisValidatorsRoot,
        dataDir = config.dataDir
      quit 1

  # The first pruning after restart may take a while..
  if config.historyMode == HistoryMode.Prune:
    dag.pruneHistory(true)

  dag

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

proc initBeaconNode*(
    T: type BeaconNode,
    rng: ref HmacDrbgContext,
    config: BeaconNodeConf,
    metadata: Eth2NetworkMetadata,
): Future[BeaconNode] {.async.} =
  var
    taskpool: TaskPoolPtr
    genesisState: ref ForkedHashedBeaconState = nil

  template cfg(): auto =
    metadata.cfg

  template eth1Network(): auto =
    metadata.eth1Network

  if not (isDir(config.databaseDir)):
    # If database directory missing, we going to use genesis state to check
    # for weak_subjectivity_period.
    genesisState =
      await fetchGenesisState(metadata, config.genesisState, config.genesisStateUrl)
    let
      genesisTime = getStateField(genesisState[], genesis_time)
      beaconClock = BeaconClock.init(genesisTime).valueOr:
        fatal "Invalid genesis time in genesis state", genesisTime
        quit 1
      currentSlot = beaconClock.now().slotOrZero()
      checkpoint = Checkpoint(
        epoch: epoch(getStateField(genesisState[], slot)),
        root: getStateField(genesisState[], latest_block_header).state_root,
      )
    # adapted from nimbus-eth2
    # if config.longRangeSync == LongRangeSyncMode.Light:
    #   if not is_within_weak_subjectivity_period(metadata.cfg, currentSlot,
    #                                             genesisState[], checkpoint):
    #     fatal WeakSubjectivityLogMessage, current_slot = currentSlot
    #     quit 1

  try:
    if config.numThreads < 0:
      fatal "The number of threads --numThreads cannot be negative."
      quit 1
    elif config.numThreads == 0:
      taskpool = TaskPoolPtr.new(numThreads = min(countProcessors(), 16))
    else:
      taskpool = TaskPoolPtr.new(numThreads = config.numThreads)

    info "Threadpool started", numThreads = taskpool.numThreads
  except Exception:
    raise newException(Defect, "Failure in taskpool initialization.")

  if metadata.genesis.kind == BakedIn:
    if config.genesisState.isSome:
      warn "The --genesis-state option has no effect on networks with built-in genesis state"

    if config.genesisStateUrl.isSome:
      warn "The --genesis-state-url option has no effect on networks with built-in genesis state"

  let
    eventBus = EventBus(
      headQueue: newAsyncEventQueue[HeadChangeInfoObject](),
      blocksQueue: newAsyncEventQueue[EventBeaconBlockObject](),
      attestQueue: newAsyncEventQueue[phase0.Attestation](),
      exitQueue: newAsyncEventQueue[SignedVoluntaryExit](),
      blsToExecQueue: newAsyncEventQueue[SignedBLSToExecutionChange](),
      propSlashQueue: newAsyncEventQueue[ProposerSlashing](),
      attSlashQueue: newAsyncEventQueue[AttesterSlashing](),
      blobSidecarQueue: newAsyncEventQueue[BlobSidecarInfoObject](),
      finalQueue: newAsyncEventQueue[FinalizationInfoObject](),
      reorgQueue: newAsyncEventQueue[ReorgInfoObject](),
      contribQueue: newAsyncEventQueue[SignedContributionAndProof](),
      finUpdateQueue:
        newAsyncEventQueue[RestVersioned[ForkedLightClientFinalityUpdate]](),
      optUpdateQueue:
        newAsyncEventQueue[RestVersioned[ForkedLightClientOptimisticUpdate]](),
    )
    db = BeaconChainDB.new(config.databaseDir, cfg, inMemory = false)

  if config.externalBeaconApiUrl.isSome and ChainDAGRef.isInitialized(db).isErr:
    let trustedBlockRoot =
      if config.trustedStateRoot.isSome or config.trustedBlockRoot.isSome:
        config.trustedBlockRoot
      elif cfg.ALTAIR_FORK_EPOCH == GENESIS_EPOCH:
        # Sync can be bootstrapped from the genesis block root
        if genesisState.isNil:
          genesisState = await fetchGenesisState(
            metadata, config.genesisState, config.genesisStateUrl
          )
        if not genesisState.isNil:
          let genesisBlockRoot = get_initial_beacon_block(genesisState[]).root
          notice "Neither `--trusted-block-root` nor `--trusted-state-root` " &
            "provided with `--external-beacon-api-url`, " &
            "falling back to genesis block root",
            externalBeaconApiUrl = config.externalBeaconApiUrl.get,
            trustedBlockRoot = config.trustedBlockRoot,
            trustedStateRoot = config.trustedStateRoot,
            genesisBlockRoot = $genesisBlockRoot
          some genesisBlockRoot
        else:
          none[Eth2Digest]()
      else:
        none[Eth2Digest]()
    if config.trustedStateRoot.isNone and trustedBlockRoot.isNone:
      warn "Ignoring `--external-beacon-api-url`, neither " &
        "`--trusted-block-root` nor `--trusted-state-root` provided",
        externalBeaconApiUrl = config.externalBeaconApiUrl.get,
        trustedBlockRoot = config.trustedBlockRoot,
        trustedStateRoot = config.trustedStateRoot
    else:
      if genesisState.isNil:
        genesisState =
          await fetchGenesisState(metadata, config.genesisState, config.genesisStateUrl)
      await db.doRunTrustedNodeSync(
        metadata,
        config.databaseDir,
        config.eraDir,
        config.externalBeaconApiUrl.get,
        config.trustedStateRoot.map do(x: Eth2Digest) -> string:
          "0x" & x.data.toHex,
        trustedBlockRoot,
        backfill = false,
        reindex = false,
        downloadDepositSnapshot = false,
        genesisState,
      )

  if config.finalizedCheckpointBlock.isSome:
    warn "--finalized-checkpoint-block has been deprecated, ignoring"

  let checkpointState =
    if config.finalizedCheckpointState.isSome:
      let checkpointStatePath = config.finalizedCheckpointState.get.string
      let tmp =
        try:
          newClone(
            readSszForkedHashedBeaconState(
              cfg, readAllBytes(checkpointStatePath).tryGet()
            )
          )
        except SszError as err:
          fatal "Checkpoint state loading failed",
            err = formatMsg(err, checkpointStatePath)
          quit 1
        except CatchableError as err:
          fatal "Failed to read checkpoint state file", err = err.msg
          quit 1

      if not getStateField(tmp[], slot).is_epoch:
        fatal "--finalized-checkpoint-state must point to a state for an epoch slot",
          slot = getStateField(tmp[], slot)
        quit 1
      tmp
    else:
      nil

  if config.finalizedDepositTreeSnapshot.isSome:
    let
      depositTreeSnapshotPath = config.finalizedDepositTreeSnapshot.get.string
      snapshot =
        try:
          SSZ.loadFile(depositTreeSnapshotPath, DepositTreeSnapshot)
        except SszError as err:
          fatal "Deposit tree snapshot loading failed",
            err = formatMsg(err, depositTreeSnapshotPath)
          quit 1
        except CatchableError as err:
          fatal "Failed to read deposit tree snapshot file", err = err.msg
          quit 1
      depositContractSnapshot = DepositContractSnapshot.init(snapshot).valueOr:
        fatal "Invalid deposit tree snapshot file"
        quit 1
    db.putDepositContractSnapshot(depositContractSnapshot)

  let engineApiUrls = config.engineApiUrls

  if engineApiUrls.len == 0:
    notice "Running without execution client - validator features disabled (see https://nimbus.guide/eth1.html)"

  var networkGenesisValidatorsRoot = metadata.bakedGenesisValidatorsRoot

  if not ChainDAGRef.isInitialized(db).isOk():
    genesisState =
      if not checkpointState.isNil and getStateField(checkpointState[], slot) == 0:
        checkpointState
      else:
        if genesisState.isNil:
          await fetchGenesisState(metadata, config.genesisState, config.genesisStateUrl)
        else:
          genesisState

    if genesisState.isNil and checkpointState.isNil:
      fatal "No database and no genesis snapshot found. Please supply a genesis.ssz " &
        "with the network configuration"
      quit 1

    if not genesisState.isNil and not checkpointState.isNil:
      if getStateField(genesisState[], genesis_validators_root) !=
          getStateField(checkpointState[], genesis_validators_root):
        fatal "Checkpoint state does not match genesis - check the --network parameter",
          rootFromGenesis = getStateField(genesisState[], genesis_validators_root),
          rootFromCheckpoint = getStateField(checkpointState[], genesis_validators_root)
        quit 1

    try:
      # Always store genesis state if we have it - this allows reindexing and
      # answering genesis queries
      if not genesisState.isNil:
        ChainDAGRef.preInit(db, genesisState[])
        networkGenesisValidatorsRoot =
          Opt.some(getStateField(genesisState[], genesis_validators_root))

      if not checkpointState.isNil:
        if genesisState.isNil or getStateField(checkpointState[], slot) != GENESIS_SLOT:
          ChainDAGRef.preInit(db, checkpointState[])

      doAssert ChainDAGRef.isInitialized(db).isOk(),
        "preInit should have initialized db"
    except CatchableError as exc:
      error "Failed to initialize database", err = exc.msg
      quit 1
  else:
    if not checkpointState.isNil:
      fatal "A database already exists, cannot start from given checkpoint",
        dataDir = config.dataDir
      quit 1

  # Doesn't use std/random directly, but dependencies might
  randomize(rng[].rand(high(int)))

  # The validatorMonitorTotals flag has been deprecated and should eventually be
  # removed - until then, it's given priority if set so as not to needlessly
  # break existing setups
  let validatorMonitor = newClone(
    ValidatorMonitor.init(
      config.validatorMonitorAuto,
      config.validatorMonitorTotals.get(not config.validatorMonitorDetails),
    )
  )

  for key in config.validatorMonitorPubkeys:
    validatorMonitor[].addMonitor(key, Opt.none(ValidatorIndex))

  let
    dag = loadChainDag(
      config, cfg, db, eventBus, validatorMonitor, networkGenesisValidatorsRoot
    )
    genesisTime = getStateField(dag.headState, genesis_time)
    beaconClock = BeaconClock.init(genesisTime).valueOr:
      fatal "Invalid genesis time in state", genesisTime
      quit 1

    getBeaconTime = beaconClock.getBeaconTimeFn()

  if config.weakSubjectivityCheckpoint.isSome:
    dag.checkWeakSubjectivityCheckpoint(
      config.weakSubjectivityCheckpoint.get, beaconClock
    )

  let elManager = ELManager.new(
    cfg, metadata.depositContractBlock, metadata.depositContractBlockHash, db,
    engineApiUrls, eth1Network,
  )

  if config.rpcEnabled.isSome:
    warn "Nimbus's JSON-RPC server has been removed. This includes the --rpc, --rpc-port, and --rpc-address configuration options. https://nimbus.guide/rest-api.html shows how to enable and configure the REST Beacon API server which replaces it."

  let restServer =
    if config.restEnabled:
      RestServerRef.init(
        config.restAddress, config.restPort, config.restAllowedOrigin,
        validateBeaconApiQueries, nimbusAgentStr, config,
      )
    else:
      nil

  let
    netKeys = getPersistentNetKeys(rng[], config)
    nickname =
      if config.nodeName == "auto":
        shortForm(netKeys)
      else:
        config.nodeName
    network = createEth2Node(
      rng,
      config,
      netKeys,
      cfg,
      dag.forkDigests,
      getBeaconTime,
      getStateField(dag.headState, genesis_validators_root),
    )

  case config.slashingDbKind
  of SlashingDbKind.v2:
    discard
  of SlashingDbKind.v1:
    error "Slashing DB v1 is no longer supported for writing"
    quit 1
  of SlashingDbKind.both:
    warn "Slashing DB v1 deprecated, writing only v2"

  info "Loading slashing protection database (v2)", path = config.validatorsDir()

  proc getValidatorAndIdx(pubkey: ValidatorPubKey): Opt[ValidatorAndIndex] =
    withState(dag.headState):
      getValidator(forkyState().data.validators.asSeq(), pubkey)

  func getCapellaForkVersion(): Opt[Version] =
    Opt.some(cfg.CAPELLA_FORK_VERSION)

  func getDenebForkEpoch(): Opt[Epoch] =
    Opt.some(cfg.DENEB_FORK_EPOCH)

  proc getForkForEpoch(epoch: Epoch): Opt[Fork] =
    Opt.some(dag.forkAtEpoch(epoch))

  proc getGenesisRoot(): Eth2Digest =
    getStateField(dag.headState, genesis_validators_root)

  let
    keystoreCache = KeystoreCacheRef.init()
    slashingProtectionDB = SlashingProtectionDB.init(
      getStateField(dag.headState, genesis_validators_root),
      config.validatorsDir(),
      SlashingDbName,
    )
    validatorPool =
      newClone(ValidatorPool.init(slashingProtectionDB, config.doppelgangerDetection))

    keymanagerInitResult = initKeymanagerServer(config, restServer)
    keymanagerHost =
      if keymanagerInitResult.server != nil:
        newClone KeymanagerHost.init(
          validatorPool, keystoreCache, rng, keymanagerInitResult.token,
          config.validatorsDir, config.secretsDir, config.defaultFeeRecipient,
          config.suggestedGasLimit, config.defaultGraffitiBytes,
          config.getPayloadBuilderAddress, getValidatorAndIdx, getBeaconTime,
          getCapellaForkVersion, getDenebForkEpoch, getForkForEpoch, getGenesisRoot,
        )
      else:
        nil

    stateTtlCache =
      if config.restCacheSize > 0:
        StateTtlCache.init(
          cacheSize = config.restCacheSize,
          cacheTtl = chronos.seconds(config.restCacheTtl),
        )
      else:
        nil

  if config.payloadBuilderEnable:
    info "Using external payload builder", payloadBuilderUrl = config.payloadBuilderUrl

  let node = BeaconNode(
    nickname: nickname,
    graffitiBytes:
      if config.graffiti.isSome:
        config.graffiti.get
      else:
        defaultGraffitiBytes(),
    network: network,
    netKeys: netKeys,
    db: db,
    config: config,
    attachedValidators: validatorPool,
    elManager: elManager,
    restServer: restServer,
    keymanagerHost: keymanagerHost,
    keymanagerServer: keymanagerInitResult.server,
    keystoreCache: keystoreCache,
    eventBus: eventBus,
    gossipState: {},
    blocksGossipState: {},
    beaconClock: beaconClock,
    validatorMonitor: validatorMonitor,
    stateTtlCache: stateTtlCache,
    shutdownEvent: newAsyncEvent(),
    dynamicFeeRecipientsStore: newClone(DynamicFeeRecipientsStore.init()),
  )

  # TODO: we are initializing the light client given that it has a function
  # to validate if the sync should be done optimistically or not, and it used
  # along beacon node
  node.initLightClient(
    rng, cfg, dag.forkDigests, getBeaconTime, dag.genesis_validators_root
  )

  await node.initFullNode(rng, dag, taskpool, getBeaconTime)

  node.updateLightClientFromDag()

  node

proc installMessageValidators(node: BeaconNode) =
  # These validators stay around the whole time, regardless of which specific
  # subnets are subscribed to during any given epoch.
  let forkDigests = node.dag.forkDigests

  for fork in ConsensusFork:
    withConsensusFork(fork):
      let digest = forkDigests[].atConsensusFork(consensusFork)

      # beacon_block
      # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/phase0/p2p-interface.md#beacon_block
      node.network.addValidator(
        getBeaconBlocksTopic(digest),
        proc(signedBlock: consensusFork.SignedBeaconBlock): ValidationResult =
          if node.shouldSyncOptimistically(node.currentSlot):
            toValidationResult(
              node.optimisticProcessor.processSignedBeaconBlock(signedBlock)
            )
          else:
            toValidationResult(
              node.processor[].processSignedBeaconBlock(MsgSource.gossip, signedBlock)
            ),
      )

      # beacon_attestation_{subnet_id}
      # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/phase0/p2p-interface.md#beacon_attestation_subnet_id
      when consensusFork >= ConsensusFork.Electra:
        for it in SubnetId:
          closureScope:
            let subnet_id = it
            node.network.addAsyncValidator(
              getAttestationTopic(digest, subnet_id),
              proc(
                  attestation: electra.Attestation
              ): Future[ValidationResult] {.async: (raises: [CancelledError]).} =
                return toValidationResult(
                  await node.processor.processAttestation(
                    MsgSource.gossip,
                    attestation,
                    subnet_id,
                    checkSignature = true,
                    checkValidator = false,
                  )
                ),
            )
      else:
        for it in SubnetId:
          closureScope:
            let subnet_id = it
            node.network.addAsyncValidator(
              getAttestationTopic(digest, subnet_id),
              proc(
                  attestation: phase0.Attestation
              ): Future[ValidationResult] {.async: (raises: [CancelledError]).} =
                return toValidationResult(
                  await node.processor.processAttestation(
                    MsgSource.gossip,
                    attestation,
                    subnet_id,
                    checkSignature = true,
                    checkValidator = false,
                  )
                ),
            )

      # beacon_aggregate_and_proof
      # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.4/specs/phase0/p2p-interface.md#beacon_aggregate_and_proof
      when consensusFork >= ConsensusFork.Electra:
        node.network.addAsyncValidator(
          getAggregateAndProofsTopic(digest),
          proc(
              signedAggregateAndProof: electra.SignedAggregateAndProof
          ): Future[ValidationResult] {.async: (raises: [CancelledError]).} =
            return toValidationResult(
              await node.processor.processSignedAggregateAndProof(
                MsgSource.gossip, signedAggregateAndProof
              )
            ),
        )
      else:
        node.network.addAsyncValidator(
          getAggregateAndProofsTopic(digest),
          proc(
              signedAggregateAndProof: phase0.SignedAggregateAndProof
          ): Future[ValidationResult] {.async: (raises: [CancelledError]).} =
            return toValidationResult(
              await node.processor.processSignedAggregateAndProof(
                MsgSource.gossip, signedAggregateAndProof
              )
            ),
        )

      # attester_slashing
      # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/phase0/p2p-interface.md#attester_slashing
      # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.6/specs/electra/p2p-interface.md#modifications-in-electra
      when consensusFork >= ConsensusFork.Electra:
        node.network.addValidator(
          getAttesterSlashingsTopic(digest),
          proc(attesterSlashing: electra.AttesterSlashing): ValidationResult =
            toValidationResult(
              node.processor[].processAttesterSlashing(
                MsgSource.gossip, attesterSlashing
              )
            ),
        )
      else:
        node.network.addValidator(
          getAttesterSlashingsTopic(digest),
          proc(attesterSlashing: phase0.AttesterSlashing): ValidationResult =
            toValidationResult(
              node.processor[].processAttesterSlashing(
                MsgSource.gossip, attesterSlashing
              )
            ),
        )

      # proposer_slashing
      # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/phase0/p2p-interface.md#proposer_slashing
      node.network.addValidator(
        getProposerSlashingsTopic(digest),
        proc(proposerSlashing: ProposerSlashing): ValidationResult =
          toValidationResult(
            node.processor[].processProposerSlashing(MsgSource.gossip, proposerSlashing)
          ),
      )

      # voluntary_exit
      # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/phase0/p2p-interface.md#voluntary_exit
      node.network.addValidator(
        getVoluntaryExitsTopic(digest),
        proc(signedVoluntaryExit: SignedVoluntaryExit): ValidationResult =
          toValidationResult(
            node.processor[].processSignedVoluntaryExit(
              MsgSource.gossip, signedVoluntaryExit
            )
          ),
      )

      when consensusFork >= ConsensusFork.Altair:
        # sync_committee_{subnet_id}
        # https://github.com/ethereum/consensus-specs/blob/v1.4.0/specs/altair/p2p-interface.md#sync_committee_subnet_id
        for subcommitteeIdx in SyncSubcommitteeIndex:
          closureScope:
            let idx = subcommitteeIdx
            node.network.addAsyncValidator(
              getSyncCommitteeTopic(digest, idx),
              proc(
                  msg: SyncCommitteeMessage
              ): Future[ValidationResult] {.async: (raises: [CancelledError]).} =
                return toValidationResult(
                  await node.processor.processSyncCommitteeMessage(
                    MsgSource.gossip, msg, idx
                  )
                ),
            )

        # sync_committee_contribution_and_proof
        # https://github.com/ethereum/consensus-specs/blob/v1.4.0/specs/altair/p2p-interface.md#sync_committee_contribution_and_proof
        node.network.addAsyncValidator(
          getSyncCommitteeContributionAndProofTopic(digest),
          proc(
              msg: SignedContributionAndProof
          ): Future[ValidationResult] {.async: (raises: [CancelledError]).} =
            return toValidationResult(
              await node.processor.processSignedContributionAndProof(
                MsgSource.gossip, msg
              )
            ),
        )

      when consensusFork >= ConsensusFork.Capella:
        # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/capella/p2p-interface.md#bls_to_execution_change
        node.network.addAsyncValidator(
          getBlsToExecutionChangeTopic(digest),
          proc(
              msg: SignedBLSToExecutionChange
          ): Future[ValidationResult] {.async: (raises: [CancelledError]).} =
            return toValidationResult(
              await node.processor.processBlsToExecutionChange(MsgSource.gossip, msg)
            ),
        )

      when consensusFork >= ConsensusFork.Deneb:
        # blob_sidecar_{subnet_id}
        # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/deneb/p2p-interface.md#blob_sidecar_subnet_id
        for it in BlobId:
          closureScope:
            let subnet_id = it
            node.network.addValidator(
              getBlobSidecarTopic(digest, subnet_id),
              proc(blobSidecar: deneb.BlobSidecar): ValidationResult =
                toValidationResult(
                  node.processor[].processBlobSidecar(
                    MsgSource.gossip, blobSidecar, subnet_id
                  )
                ),
            )

  # node.installLightClientMessageValidators()

proc checkWeakSubjectivityCheckpoint(
    dag: ChainDAGRef, wsCheckpoint: Checkpoint, beaconClock: BeaconClock
) =
  let
    currentSlot = beaconClock.now.slotOrZero
    isCheckpointStale =
      not is_within_weak_subjectivity_period(
        dag.cfg, currentSlot, dag.headState, wsCheckpoint
      )

  if isCheckpointStale:
    error "Weak subjectivity checkpoint is stale",
      currentSlot,
      checkpoint = wsCheckpoint,
      headStateSlot = getStateField(dag.headState, slot)
    quit 1

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

proc pruneBlobs(node: BeaconNode, slot: Slot) =
  let blobPruneEpoch =
    (slot.epoch - node.dag.cfg.MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS - 1)
  if slot.is_epoch() and blobPruneEpoch >= node.dag.cfg.DENEB_FORK_EPOCH:
    var blocks: array[SLOTS_PER_EPOCH.int, BlockId]
    var count = 0
    let startIndex = node.dag.getBlockRange(
      blobPruneEpoch.start_slot, 1, blocks.toOpenArray(0, SLOTS_PER_EPOCH - 1)
    )
    for i in startIndex ..< SLOTS_PER_EPOCH:
      let blck = node.dag.getForkedBlock(blocks[int(i)]).valueOr:
        continue
      withBlck(blck):
        when typeof(forkyBlck).kind < ConsensusFork.Deneb:
          continue
        else:
          for j in 0 .. len(forkyBlck.message.body.blob_kzg_commitments) - 1:
            if node.db.delBlobSidecar(blocks[int(i)].root, BlobIndex(j)):
              count = count + 1
    debug "pruned blobs", count, blobPruneEpoch

proc maybeUpdateActionTrackerNextEpoch(
    node: BeaconNode, forkyState: ForkyHashedBeaconState, nextEpoch: Epoch
) =
  if node.consensusManager[].actionTracker.needsUpdate(forkyState, nextEpoch):
    template epochRefFallback() =
      let epochRef = node.dag.getEpochRef(node.dag.head, nextEpoch, false).expect(
          "Getting head EpochRef should never fail"
        )
      node.consensusManager[].actionTracker.updateActions(
        epochRef.shufflingRef, epochRef.beacon_proposers
      )

    when forkyState is phase0.HashedBeaconState:
      # The previous_epoch_participation-based logic requires Altair or newer
      epochRefFallback()
    else:
      let
        shufflingRef = node.dag.getShufflingRef(node.dag.head, nextEpoch, false).valueOr:
          # epochRefFallback() won't work in this case either
          return
        nextEpochProposers = get_beacon_proposer_indices(
          forkyState.data, shufflingRef.shuffled_active_validator_indices, nextEpoch
        )
        nextEpochFirstProposer = nextEpochProposers[0].valueOr:
          # All proposers except the first can be more straightforwardly and
          # efficiently (re)computed correctly once in that epoch.
          epochRefFallback()
          return

      # Has to account for potential epoch transition TIMELY_SOURCE_FLAG_INDEX,
      # TIMELY_TARGET_FLAG_INDEX, and inactivity penalties, resulting from spec
      # functions get_flag_index_deltas() and get_inactivity_penalty_deltas().
      #
      # There are no penalties associated with TIMELY_HEAD_FLAG_INDEX, but a
      # reward exists. effective_balance == MAX_EFFECTIVE_BALANCE.Gwei ensures
      # if even so, then the effective balance cannot change as a result.
      #
      # It's not truly necessary to avoid all rewards and penalties, but only
      # to bound them to ensure they won't unexpected alter effective balance
      # during the upcoming epoch transition.
      #
      # During genesis epoch, the check for epoch participation is against
      # current, not previous, epoch, and therefore there's a possibility of
      # checking for if a validator has participated in an epoch before it will
      # happen.
      #
      # Because process_rewards_and_penalties() in epoch processing happens
      # before the current/previous participation swap, previous is correct
      # even here, and consistent with what the epoch transition uses.
      #
      # Whilst slashing, proposal, and sync committee rewards and penalties do
      # update the balances as they occur, they don't update effective_balance
      # until the end of epoch, so detect via effective_balance_might_update.
      #
      # On EF mainnet epoch 233906, this matches 99.5% of active validators;
      # with Holesky epoch 2041, 83% of active validators.
      let
        participation_flags =
          forkyState.data.previous_epoch_participation.item(nextEpochFirstProposer)
        effective_balance =
          forkyState.data.validators.item(nextEpochFirstProposer).effective_balance

      if participation_flags.has_flag(TIMELY_SOURCE_FLAG_INDEX) and
          participation_flags.has_flag(TIMELY_TARGET_FLAG_INDEX) and
          effective_balance == MAX_EFFECTIVE_BALANCE.Gwei and
          forkyState.data.slot.epoch != GENESIS_EPOCH and
          forkyState.data.inactivity_scores.item(nextEpochFirstProposer) == 0 and
          not effective_balance_might_update(
            forkyState.data.balances.item(nextEpochFirstProposer), effective_balance
          ):
        node.consensusManager[].actionTracker.updateActions(
          shufflingRef, nextEpochProposers
        )
      else:
        epochRefFallback()

func hasSyncPubKey(node: BeaconNode, epoch: Epoch): auto =
  # Only used to determine which gossip topics to which to subscribe
  if node.config.subscribeAllSubnets:
    (
      func (pubkey: ValidatorPubKey): bool {.closure.} =
        true
    )
  else:
    (
      func (pubkey: ValidatorPubKey): bool =
        node.consensusManager[].actionTracker.hasSyncDuty(pubkey, epoch) or
          pubkey in node.attachedValidators[].validators
    )

func getCurrentSyncCommiteeSubnets(node: BeaconNode, epoch: Epoch): SyncnetBits =
  let syncCommittee = withState(node.dag.headState):
    when consensusFork >= ConsensusFork.Altair:
      forkyState.data.current_sync_committee
    else:
      return static(default(SyncnetBits))

  getSyncSubnets(node.hasSyncPubKey(epoch), syncCommittee)

func getNextSyncCommitteeSubnets(node: BeaconNode, epoch: Epoch): SyncnetBits =
  let syncCommittee = withState(node.dag.headState):
    when consensusFork >= ConsensusFork.Altair:
      forkyState.data.next_sync_committee
    else:
      return static(default(SyncnetBits))

  getSyncSubnets(
    node.hasSyncPubKey((epoch.sync_committee_period + 1).start_slot().epoch),
    syncCommittee,
  )

func getSyncCommitteeSubnets(node: BeaconNode, epoch: Epoch): SyncnetBits =
  let
    subnets = node.getCurrentSyncCommiteeSubnets(epoch)
    epochsToSyncPeriod = nearSyncCommitteePeriod(epoch)

  # The end-slot tracker might call this when it's theoretically applicable,
  # but more than SYNC_COMMITTEE_SUBNET_COUNT epochs from when the next sync
  # committee period begins, in which case `epochsToNextSyncPeriod` is none.
  if epochsToSyncPeriod.isNone or
      node.dag.cfg.consensusForkAtEpoch(epoch + epochsToSyncPeriod.get) <
      ConsensusFork.Altair:
    return subnets

  subnets + node.getNextSyncCommitteeSubnets(epoch)

func forkDigests(node: BeaconNode): auto =
  let forkDigestsArray: array[ConsensusFork, auto] = [
    node.dag.forkDigests.phase0, node.dag.forkDigests.altair,
    node.dag.forkDigests.bellatrix, node.dag.forkDigests.capella,
    node.dag.forkDigests.deneb, node.dag.forkDigests.electra,
  ]
  forkDigestsArray

proc updateSyncCommitteeTopics(node: BeaconNode, slot: Slot) =
  template lastSyncUpdate(): untyped =
    node.consensusManager[].actionTracker.lastSyncUpdate

  if lastSyncUpdate == Opt.some(slot.sync_committee_period()) and
      nearSyncCommitteePeriod(slot.epoch).isNone():
    # No need to update unless we're close to the next sync committee period or
    # new validators were registered with the action tracker
    # TODO we _could_ skip running this in some of the "near" slots, but..
    return

  lastSyncUpdate = Opt.some(slot.sync_committee_period())

  let syncnets = node.getSyncCommitteeSubnets(slot.epoch)

  debug "Updating sync committee subnets",
    syncnets,
    metadata_syncnets = node.network.metadata.syncnets,
    gossipState = node.gossipState

  # Assume that different gossip fork sync committee setups are in sync; this
  # only remains relevant, currently, for one gossip transition epoch, so the
  # consequences of this not being true aren't exceptionally dire, while this
  # allows for bookkeeping simplication.
  if syncnets == node.network.metadata.syncnets:
    return

  let
    newSyncnets = syncnets - node.network.metadata.syncnets
    oldSyncnets = node.network.metadata.syncnets - syncnets
    forkDigests = node.forkDigests()

  for subcommitteeIdx in SyncSubcommitteeIndex:
    doAssert not (newSyncnets[subcommitteeIdx] and oldSyncnets[subcommitteeIdx])
    for gossipFork in node.gossipState:
      template topic(): auto =
        getSyncCommitteeTopic(forkDigests[gossipFork], subcommitteeIdx)

      if oldSyncnets[subcommitteeIdx]:
        node.network.unsubscribe(topic)
      elif newSyncnets[subcommitteeIdx]:
        node.network.subscribe(topic, basicParams)

  node.network.updateSyncnetsMetadata(syncnets)

proc removePhase0MessageHandlers(node: BeaconNode, forkDigest: ForkDigest) =
  node.network.unsubscribe(getVoluntaryExitsTopic(forkDigest))
  node.network.unsubscribe(getProposerSlashingsTopic(forkDigest))
  node.network.unsubscribe(getAttesterSlashingsTopic(forkDigest))
  node.network.unsubscribe(getAggregateAndProofsTopic(forkDigest))

  for subnet_id in SubnetId:
    node.network.unsubscribe(getAttestationTopic(forkDigest, subnet_id))

  node.consensusManager[].actionTracker.subscribedSubnets = default(AttnetBits)

# updateAttestationSubnetHandlers subscribes attestation subnets
proc addPhase0MessageHandlers(node: BeaconNode, forkDigest: ForkDigest, slot: Slot) =
  node.network.subscribe(getAttesterSlashingsTopic(forkDigest), basicParams)
  node.network.subscribe(getProposerSlashingsTopic(forkDigest), basicParams)
  node.network.subscribe(getVoluntaryExitsTopic(forkDigest), basicParams)
  node.network.subscribe(
    getAggregateAndProofsTopic(forkDigest),
    aggregateTopicParams,
    enableTopicMetrics = true,
  )

proc addAltairMessageHandlers(node: BeaconNode, forkDigest: ForkDigest, slot: Slot) =
  node.addPhase0MessageHandlers(forkDigest, slot)

  # If this comes online near sync committee period, it'll immediately get
  # replaced as usual by trackSyncCommitteeTopics, which runs at slot end.
  let syncnets = node.getSyncCommitteeSubnets(slot.epoch)

  for subcommitteeIdx in SyncSubcommitteeIndex:
    if syncnets[subcommitteeIdx]:
      node.network.subscribe(
        getSyncCommitteeTopic(forkDigest, subcommitteeIdx), basicParams
      )

  node.network.subscribe(
    getSyncCommitteeContributionAndProofTopic(forkDigest), basicParams
  )

  node.network.updateSyncnetsMetadata(syncnets)

proc addCapellaMessageHandlers(node: BeaconNode, forkDigest: ForkDigest, slot: Slot) =
  node.addAltairMessageHandlers(forkDigest, slot)
  node.network.subscribe(getBlsToExecutionChangeTopic(forkDigest), basicParams)

proc addDenebMessageHandlers(node: BeaconNode, forkDigest: ForkDigest, slot: Slot) =
  node.addCapellaMessageHandlers(forkDigest, slot)
  for topic in blobSidecarTopics(forkDigest):
    node.network.subscribe(topic, basicParams)

proc addElectraMessageHandlers(node: BeaconNode, forkDigest: ForkDigest, slot: Slot) =
  node.addDenebMessageHandlers(forkDigest, slot)

proc removeAltairMessageHandlers(node: BeaconNode, forkDigest: ForkDigest) =
  node.removePhase0MessageHandlers(forkDigest)

  for subcommitteeIdx in SyncSubcommitteeIndex:
    closureScope:
      let idx = subcommitteeIdx
      node.network.unsubscribe(getSyncCommitteeTopic(forkDigest, idx))

  node.network.unsubscribe(getSyncCommitteeContributionAndProofTopic(forkDigest))

proc removeCapellaMessageHandlers(node: BeaconNode, forkDigest: ForkDigest) =
  node.removeAltairMessageHandlers(forkDigest)
  node.network.unsubscribe(getBlsToExecutionChangeTopic(forkDigest))

proc removeDenebMessageHandlers(node: BeaconNode, forkDigest: ForkDigest) =
  node.removeCapellaMessageHandlers(forkDigest)
  for topic in blobSidecarTopics(forkDigest):
    node.network.unsubscribe(topic)

proc removeElectraMessageHandlers(node: BeaconNode, forkDigest: ForkDigest) =
  node.removeDenebMessageHandlers(forkDigest)

proc doppelgangerChecked(node: BeaconNode, epoch: Epoch) =
  if not node.processor[].doppelgangerDetectionEnabled:
    return

  # broadcastStartEpoch is set to FAR_FUTURE_EPOCH when we're not monitoring
  # gossip - it is only viable to assert liveness in epochs where gossip is
  # active
  if epoch > node.processor[].doppelgangerDetection.broadcastStartEpoch:
    for validator in node.attachedValidators[]:
      validator.doppelgangerChecked(epoch - 1)

proc updateBlocksGossipStatus*(node: BeaconNode, slot: Slot, dagIsBehind: bool) =
  template cfg(): auto =
    node.dag.cfg

  let
    isBehind =
      if node.shouldSyncOptimistically(slot):
        # If optimistic sync is active, always subscribe to blocks gossip
        false
      else:
        # Use DAG status to determine whether to subscribe for blocks gossip
        dagIsBehind

    targetGossipState = getTargetGossipState(
      slot.epoch, cfg.ALTAIR_FORK_EPOCH, cfg.BELLATRIX_FORK_EPOCH,
      cfg.CAPELLA_FORK_EPOCH, cfg.DENEB_FORK_EPOCH, cfg.ELECTRA_FORK_EPOCH, isBehind,
    )

  template currentGossipState(): auto =
    node.blocksGossipState

  if currentGossipState == targetGossipState:
    return

  if currentGossipState.card == 0 and targetGossipState.card > 0:
    debug "Enabling blocks topic subscriptions", wallSlot = slot, targetGossipState
  elif currentGossipState.card > 0 and targetGossipState.card == 0:
    debug "Disabling blocks topic subscriptions", wallSlot = slot
  else:
    # Individual forks added / removed
    discard

  let
    newGossipForks = targetGossipState - currentGossipState
    oldGossipForks = currentGossipState - targetGossipState

  for gossipFork in oldGossipForks:
    let forkDigest = node.dag.forkDigests[].atConsensusFork(gossipFork)
    node.network.unsubscribe(getBeaconBlocksTopic(forkDigest))

  for gossipFork in newGossipForks:
    let forkDigest = node.dag.forkDigests[].atConsensusFork(gossipFork)
    node.network.subscribe(
      getBeaconBlocksTopic(forkDigest), blocksTopicParams, enableTopicMetrics = true
    )

  node.blocksGossipState = targetGossipState

func subnetLog(v: BitArray): string =
  $toSeq(v.oneIndices())

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/phase0/p2p-interface.md#attestation-subnet-subscription
proc updateAttestationSubnetHandlers(node: BeaconNode, slot: Slot) =
  if node.gossipState.card == 0:
    # When disconnected, updateBlocksGossipStatus is responsible for all things
    # subnets - in particular, it will remove subscriptions on the edge where
    # we enter the disconnected state.
    return

  let
    aggregateSubnets = node.consensusManager[].actionTracker.aggregateSubnets(slot)
    stabilitySubnets = node.consensusManager[].actionTracker.stabilitySubnets(slot)
    subnets = aggregateSubnets + stabilitySubnets

  node.network.updateStabilitySubnetMetadata(stabilitySubnets)

  # Now we know what we should be subscribed to - make it so
  let
    prevSubnets = node.consensusManager[].actionTracker.subscribedSubnets
    unsubscribeSubnets = prevSubnets - subnets
    subscribeSubnets = subnets - prevSubnets

  # Remember what we subscribed to, so we can unsubscribe later
  node.consensusManager[].actionTracker.subscribedSubnets = subnets

  let forkDigests = node.forkDigests()

  for gossipFork in node.gossipState:
    let forkDigest = forkDigests[gossipFork]
    node.network.unsubscribeAttestationSubnets(unsubscribeSubnets, forkDigest)
    node.network.subscribeAttestationSubnets(subscribeSubnets, forkDigest)

  debug "Attestation subnets",
    slot,
    epoch = slot.epoch,
    gossipState = node.gossipState,
    stabilitySubnets = subnetLog(stabilitySubnets),
    aggregateSubnets = subnetLog(aggregateSubnets),
    prevSubnets = subnetLog(prevSubnets),
    subscribeSubnets = subnetLog(subscribeSubnets),
    unsubscribeSubnets = subnetLog(unsubscribeSubnets),
    gossipState = node.gossipState

#TODO: overriden due to shadowing from
proc localUpdateGossipStatus(node: BeaconNode, slot: Slot) {.async.} =
  ## Subscribe to subnets that we are providing stability for or aggregating
  ## and unsubscribe from the ones that are no longer relevant.

  # Let the tracker know what duties are approaching - this will tell us how
  # many stability subnets we need to be subscribed to and what subnets we'll
  # soon be aggregating - in addition to the in-beacon-node duties, there may
  # also be duties coming from the validator client, but we don't control when
  # these arrive
  await node.registerDuties(slot)

  # We start subscribing to gossip before we're fully synced - this allows time
  # to subscribe before the sync end game
  const
    TOPIC_SUBSCRIBE_THRESHOLD_SLOTS = 64
    HYSTERESIS_BUFFER = 16

  static:
    doAssert high(ConsensusFork) == ConsensusFork.Electra

  let
    head = node.dag.head
    headDistance =
      if slot > head.slot:
        (slot - head.slot).uint64
      else:
        0'u64
    isBehind = headDistance > TOPIC_SUBSCRIBE_THRESHOLD_SLOTS + HYSTERESIS_BUFFER
    targetGossipState = getTargetGossipState(
      slot.epoch, node.dag.cfg.ALTAIR_FORK_EPOCH, node.dag.cfg.BELLATRIX_FORK_EPOCH,
      node.dag.cfg.CAPELLA_FORK_EPOCH, node.dag.cfg.DENEB_FORK_EPOCH,
      node.dag.cfg.ELECTRA_FORK_EPOCH, isBehind,
    )

  doAssert targetGossipState.card <= 2

  let
    newGossipForks = targetGossipState - node.gossipState
    oldGossipForks = node.gossipState - targetGossipState

  doAssert newGossipForks.card <= 2
  doAssert oldGossipForks.card <= 2

  func maxGossipFork(gossipState: GossipState): int =
    var res = -1
    for gossipFork in gossipState:
      res = max(res, gossipFork.int)
    res

  if maxGossipFork(targetGossipState) < maxGossipFork(node.gossipState) and
      targetGossipState != {}:
    warn "Unexpected clock regression during transition",
      targetGossipState, gossipState = node.gossipState

  if node.gossipState.card == 0 and targetGossipState.card > 0:
    # We are synced, so we will connect
    debug "Enabling topic subscriptions",
      wallSlot = slot, headSlot = head.slot, headDistance, targetGossipState

    node.processor[].setupDoppelgangerDetection(slot)

    # Specially when waiting for genesis, we'll already be synced on startup -
    # it might also happen on a sufficiently fast restart

    # We "know" the actions for the current and the next epoch
    withState(node.dag.headState):
      if node.consensusManager[].actionTracker.needsUpdate(forkyState, slot.epoch):
        let epochRef = node.dag.getEpochRef(head, slot.epoch, false).expect(
            "Getting head EpochRef should never fail"
          )
        node.consensusManager[].actionTracker.updateActions(
          epochRef.shufflingRef, epochRef.beacon_proposers
        )

      node.maybeUpdateActionTrackerNextEpoch(forkyState, slot.epoch + 1)

  if node.gossipState.card > 0 and targetGossipState.card == 0:
    debug "Disabling topic subscriptions",
      wallSlot = slot, headSlot = head.slot, headDistance

    node.processor[].clearDoppelgangerProtection()

  let forkDigests = node.forkDigests()

  const removeMessageHandlers: array[ConsensusFork, auto] = [
    removePhase0MessageHandlers,
    removeAltairMessageHandlers,
    removeAltairMessageHandlers, # bellatrix (altair handlers, different forkDigest)
    removeCapellaMessageHandlers,
    removeDenebMessageHandlers,
    removeElectraMessageHandlers,
  ]

  for gossipFork in oldGossipForks:
    removeMessageHandlers[gossipFork](node, forkDigests[gossipFork])

  const addMessageHandlers: array[ConsensusFork, auto] = [
    addPhase0MessageHandlers,
    addAltairMessageHandlers,
    addAltairMessageHandlers, # bellatrix (altair handlers, different forkDigest)
    addCapellaMessageHandlers,
    addDenebMessageHandlers,
    addElectraMessageHandlers,
  ]

  for gossipFork in newGossipForks:
    addMessageHandlers[gossipFork](node, forkDigests[gossipFork], slot)

  node.gossipState = targetGossipState
  node.doppelgangerChecked(slot.epoch)
  node.updateAttestationSubnetHandlers(slot)
  node.updateBlocksGossipStatus(slot, isBehind)
  # node.updateLightClientGossipStatus(slot, isBehind)

proc onSlotEnd(node: BeaconNode, slot: Slot) {.async.} =
  # Things we do when slot processing has ended and we're about to wait for the
  # next slot

  # By waiting until close before slot end, ensure that preparation for next
  # slot does not interfere with propagation of messages and with VC duties.
  const endOffset =
    aggregateSlotOffset +
    nanos((NANOSECONDS_PER_SLOT - aggregateSlotOffset.nanoseconds.uint64).int64 div 2)
  let endCutoff = node.beaconClock.fromNow(slot.start_beacon_time + endOffset)
  if endCutoff.inFuture:
    debug "Waiting for slot end", slot, endCutoff = shortLog(endCutoff.offset)
    await sleepAsync(endCutoff.offset)

  if node.dag.needStateCachesAndForkChoicePruning():
    if node.attachedValidators[].validators.len > 0:
      node.attachedValidators[].slashingProtection
      # pruning is only done if the DB is set to pruning mode.
      .pruneAfterFinalization(node.dag.finalizedHead.slot.epoch())

  # Delay part of pruning until latency critical duties are done.
  # The other part of pruning, `pruneBlocksDAG`, is done eagerly.
  # ----
  # This is the last pruning to do as it clears the "needPruning" condition.
  node.consensusManager[].pruneStateCachesAndForkChoice()

  if node.config.historyMode == HistoryMode.Prune:
    if not (slot + 1).is_epoch():
      # The epoch slot already is "heavy" due to the epoch processing, leave
      # the pruning for later
      node.dag.pruneHistory()
      node.pruneBlobs(slot)

  when declared(GC_fullCollect):
    # The slots in the beacon node work as frames in a game: we want to make
    # sure that we're ready for the next one and don't get stuck in lengthy
    # garbage collection tasks when time is of essence in the middle of a slot -
    # while this does not guarantee that we'll never collect during a slot, it
    # makes sure that all the scratch space we used during slot tasks (logging,
    # temporary buffers etc) gets recycled for the next slot that is likely to
    # need similar amounts of memory.
    try:
      GC_fullCollect()
    except Defect as exc:
      raise exc # Reraise to maintain call stack
    except Exception:
      # TODO upstream
      raiseAssert "Unexpected exception during GC collection"
  let gcCollectionTick = Moment.now()

  # Checkpoint the database to clear the WAL file and make sure changes in
  # the database are synced with the filesystem.
  node.db.checkpoint()
  let
    dbCheckpointTick = Moment.now()
    dbCheckpointDur = dbCheckpointTick - gcCollectionTick
  # db_checkpoint_seconds.inc(dbCheckpointDur.toFloatSeconds)
  if dbCheckpointDur >= MinSignificantProcessingDuration:
    info "Database checkpointed", dur = dbCheckpointDur
  else:
    debug "Database checkpointed", dur = dbCheckpointDur

  node.syncCommitteeMsgPool[].pruneData(slot)
  if slot.is_epoch:
    node.dynamicFeeRecipientsStore[].pruneOldMappings(slot.epoch)

  # Update upcoming actions - we do this every slot in case a reorg happens
  let head = node.dag.head
  if node.isSynced(head) and head.executionValid:
    withState(node.dag.headState):
      # maybeUpdateActionTrackerNextEpoch might not account for balance changes
      # from the process_rewards_and_penalties() epoch transition but only from
      # process_block() and other per-slot sources. This mainly matters insofar
      # as it might trigger process_effective_balance_updates() changes in that
      # same epoch transition, which function is therefore potentially blind to
      # but which might then affect beacon proposers.
      #
      # Because this runs every slot, it can account naturally for slashings,
      # which affect balances via slash_validator() when they happen, and any
      # missed sync committee participation via process_sync_aggregate(), but
      # attestation penalties for example, need, specific handling.
      # checked by maybeUpdateActionTrackerNextEpoch.
      node.maybeUpdateActionTrackerNextEpoch(forkyState, slot.epoch + 1)

  let
    nextAttestationSlot =
      node.consensusManager[].actionTracker.getNextAttestationSlot(slot)
    nextProposalSlot = node.consensusManager[].actionTracker.getNextProposalSlot(slot)
    nextActionSlot = min(nextAttestationSlot, nextProposalSlot)
    nextActionWaitTime = saturate(fromNow(node.beaconClock, nextActionSlot))

  # -1 is a more useful output than 18446744073709551615 as an indicator of
  # no future attestation/proposal known.
  template formatInt64(x: Slot): int64 =
    if x == high(uint64).Slot:
      -1'i64
    else:
      toGaugeValue(x)

  let
    syncCommitteeSlot = slot + 1
    syncCommitteeEpoch = syncCommitteeSlot.epoch
    inCurrentSyncCommittee =
      not node.getCurrentSyncCommiteeSubnets(syncCommitteeEpoch).isZeros()

  template formatSyncCommitteeStatus(): string =
    if inCurrentSyncCommittee:
      "current"
    elif not node.getNextSyncCommitteeSubnets(syncCommitteeEpoch).isZeros():
      let slotsToNextSyncCommitteePeriod =
        SLOTS_PER_SYNC_COMMITTEE_PERIOD -
        since_sync_committee_period_start(syncCommitteeSlot)
      # int64 conversion is safe
      doAssert slotsToNextSyncCommitteePeriod <= SLOTS_PER_SYNC_COMMITTEE_PERIOD
      "in " &
        toTimeLeftString(
          SECONDS_PER_SLOT.int64.seconds * slotsToNextSyncCommitteePeriod.int64
        )
    else:
      "none"

  info "Slot end",
    slot = shortLog(slot),
    nextActionWait =
      if nextActionSlot == FAR_FUTURE_SLOT:
        "n/a"
      else:
        shortLog(nextActionWaitTime),
    nextAttestationSlot = formatInt64(nextAttestationSlot),
    nextProposalSlot = formatInt64(nextProposalSlot),
    syncCommitteeDuties = formatSyncCommitteeStatus(),
    head = shortLog(head)

  # if nextActionSlot != FAR_FUTURE_SLOT:
  #   next_action_wait.set(nextActionWaitTime.toFloatSeconds)

  # next_proposal_wait.set(
  #   if nextProposalSlot != FAR_FUTURE_SLOT:
  #     saturate(fromNow(node.beaconClock, nextProposalSlot)).toFloatSeconds()
  #   else:
  #     Inf)

  # sync_committee_active.set(if inCurrentSyncCommittee: 1 else: 0)

  let epoch = slot.epoch
  if epoch + 1 >= node.network.forkId.next_fork_epoch:
    # Update 1 epoch early to block non-fork-ready peers
    node.network.updateForkId(epoch, node.dag.genesis_validators_root)

  # When we're not behind schedule, we'll speculatively update the clearance
  # state in anticipation of receiving the next block - we do it after
  # logging slot end since the nextActionWaitTime can be short
  let advanceCutoff = node.beaconClock.fromNow(
    slot.start_beacon_time() + chronos.seconds(int(SECONDS_PER_SLOT - 1))
  )
  if advanceCutoff.inFuture:
    # We wait until there's only a second left before the next slot begins, then
    # we advance the clearance state to the next slot - this gives us a high
    # probability of being prepared for the block that will arrive and the
    # epoch processing that follows
    await sleepAsync(advanceCutoff.offset)
    node.dag.advanceClearanceState()

  # Prepare action tracker for the next slot
  node.consensusManager[].actionTracker.updateSlot(slot + 1)

  # The last thing we do is to perform the subscriptions and unsubscriptions for
  # the next slot, just before that slot starts - because of the advance cuttoff
  # above, this will be done just before the next slot starts
  node.updateSyncCommitteeTopics(slot + 1)

  await node.localUpdateGossipStatus(slot + 1)

func formatNextConsensusFork(node: BeaconNode, withVanityArt = false): Opt[string] =
  let consensusFork = node.dag.cfg.consensusForkAtEpoch(node.dag.head.slot.epoch)
  if consensusFork == ConsensusFork.high:
    return Opt.none(string)
  let
    nextConsensusFork = consensusFork.succ()
    nextForkEpoch = node.dag.cfg.consensusForkEpoch(nextConsensusFork)
  if nextForkEpoch == FAR_FUTURE_EPOCH:
    return Opt.none(string)
  Opt.some(
    (if withVanityArt: nextConsensusFork.getVanityMascot & " " else: "") &
      $nextConsensusFork & ":" & $nextForkEpoch
  )

func syncStatus(node: BeaconNode, wallSlot: Slot): string =
  let optimisticHead = not node.dag.head.executionValid
  if node.syncManager.inProgress:
    let
      optimisticSuffix = if optimisticHead: "/opt" else: ""
      # lightClientSuffix =
      #   if node.consensusManager[].shouldSyncOptimistically(wallSlot):
      #     " - lc: " & $shortLog(node.consensusManager[].optimisticHead)
      #   else:
      #     ""
    node.syncManager.syncStatus & optimisticSuffix #& lightClientSuffix
  elif node.backfiller.inProgress:
    "backfill: " & node.backfiller.syncStatus
  elif optimisticHead:
    "synced/opt"
  else:
    "synced"

func connectedPeersCount(node: BeaconNode): int =
  len(node.network.peerPool)

func formatGwei(amount: Gwei): string =
  # TODO This is implemented in a quite a silly way.
  # Better routines for formatting decimal numbers
  # should exists somewhere else.
  let
    eth = distinctBase(amount) div 1000000000
    remainder = distinctBase(amount) mod 1000000000

  result = $eth
  if remainder != 0:
    result.add '.'
    let remainderStr = $remainder
    for i in remainderStr.len ..< 9:
      result.add '0'
    result.add remainderStr
    while result[^1] == '0':
      result.setLen(result.len - 1)

when not defined(windows):
  proc initStatusBar(node: BeaconNode) {.raises: [ValueError].} =
    if not isatty(stdout):
      return
    if not node.config.statusBarEnabled:
      return

    try:
      enableTrueColors()
    except Exception as exc: # TODO Exception
      error "Couldn't enable colors", err = exc.msg

    proc dataResolver(expr: string): string {.raises: [].} =
      template justified(): untyped =
        node.dag.head.atEpochStart(
          getStateField(node.dag.headState, current_justified_checkpoint).epoch
        )

      # TODO:
      # We should introduce a general API for resolving dot expressions
      # such as `db.latest_block.slot` or `metrics.connected_peers`.
      # Such an API can be shared between the RPC back-end, CLI tools
      # such as ncli, a potential GraphQL back-end and so on.
      # The status bar feature would allow the user to specify an
      # arbitrary expression that is resolvable through this API.
      case expr.toLowerAscii
      of "version":
        versionAsStr
      of "full_version":
        fullVersionStr
      of "connected_peers":
        $(node.connectedPeersCount)
      of "head_root":
        shortLog(node.dag.head.root)
      of "head_epoch":
        $(node.dag.head.slot.epoch)
      of "head_epoch_slot":
        $(node.dag.head.slot.since_epoch_start)
      of "head_slot":
        $(node.dag.head.slot)
      of "justifed_root":
        shortLog(justified.blck.root)
      of "justifed_epoch":
        $(justified.slot.epoch)
      of "justifed_epoch_slot":
        $(justified.slot.since_epoch_start)
      of "justifed_slot":
        $(justified.slot)
      of "finalized_root":
        shortLog(node.dag.finalizedHead.blck.root)
      of "finalized_epoch":
        $(node.dag.finalizedHead.slot.epoch)
      of "finalized_epoch_slot":
        $(node.dag.finalizedHead.slot.since_epoch_start)
      of "finalized_slot":
        $(node.dag.finalizedHead.slot)
      of "epoch":
        $node.currentSlot.epoch
      of "epoch_slot":
        $(node.currentSlot.since_epoch_start)
      of "slot":
        $node.currentSlot
      of "slots_per_epoch":
        $SLOTS_PER_EPOCH
      of "slot_trailing_digits":
        var slotStr = $node.currentSlot
        if slotStr.len > 3:
          slotStr = slotStr[^3 ..^ 1]
        slotStr
      of "attached_validators_balance":
        formatGwei(node.attachedValidatorBalanceTotal)
      of "next_consensus_fork":
        let nextConsensusForkDescription =
          node.formatNextConsensusFork(withVanityArt = true)
        if nextConsensusForkDescription.isNone:
          ""
        else:
          " (scheduled " & nextConsensusForkDescription.get & ")"
      of "sync_status":
        node.syncStatus(node.currentSlot)
      else:
        # We ignore typos for now and just render the expression
        # as it was written. TODO: come up with a good way to show
        # an error message to the user.
        "$" & expr

    var statusBar = StatusBarView.init(node.config.statusBarContents, dataResolver)

    when compiles(defaultChroniclesStream.outputs[0].writer):
      let tmp = defaultChroniclesStream.outputs[0].writer

      defaultChroniclesStream.outputs[0].writer = proc(
          logLevel: LogLevel, msg: LogOutputStr
      ) {.raises: [].} =
        try:
          # p.hidePrompt
          erase statusBar
          # p.writeLine msg
          tmp(logLevel, msg)
          render statusBar
          # p.showPrompt
        except Exception as e: # render raises Exception
          logLoggingFailure(cstring(msg), e)

    proc statusBarUpdatesPollingLoop() {.async.} =
      try:
        while true:
          update statusBar
          erase statusBar
          render statusBar
          await sleepAsync(chronos.seconds(1))
      except CatchableError as exc:
        warn "Failed to update status bar, no further updates", err = exc.msg

    asyncSpawn statusBarUpdatesPollingLoop()

proc initializeNetworking(node: BeaconNode) {.async.} =
  node.installMessageValidators()

  info "Listening to incoming network requests"
  await node.network.startListening()

  let addressFile = node.config.dataDir / "beacon_node.enr"
  writeFile(addressFile, node.network.announcedENR.toURI)

  await node.network.start()

proc installRestHandlers(restServer: RestServerRef, node: BeaconNode) =
  restServer.router.installBeaconApiHandlers(node)
  restServer.router.installBuilderApiHandlers(node)
  restServer.router.installConfigApiHandlers(node)
  restServer.router.installDebugApiHandlers(node)
  restServer.router.installEventApiHandlers(node)
  restServer.router.installNimbusApiHandlers(node)
  restServer.router.installNodeApiHandlers(node)
  restServer.router.installValidatorApiHandlers(node)
  restServer.router.installRewardsApiHandlers(node)
  if node.dag.lcDataStore.serve:
    restServer.router.installLightClientApiHandlers(node)

from beacon_chain/spec/datatypes/capella import SignedBeaconBlock

proc stop(node: BeaconNode) =
  bnStatus = BeaconNodeStatus.Stopping
  notice "Graceful shutdown"
  if not node.config.inProcessValidators:
    try:
      node.vcProcess.close()
    except Exception as exc:
      warn "Couldn't close vc process", msg = exc.msg
  try:
    waitFor node.network.stop()
  except CatchableError as exc:
    warn "Couldn't stop network", msg = exc.msg

  node.attachedValidators[].slashingProtection.close()
  node.attachedValidators[].close()
  node.db.close()
  notice "Databases closed"

func verifyFinalization(node: BeaconNode, slot: Slot) =
  # Epoch must be >= 4 to check finalization
  const SETTLING_TIME_OFFSET = 1'u64
  let epoch = slot.epoch()

  # Don't static-assert this -- if this isn't called, don't require it
  doAssert SLOTS_PER_EPOCH > SETTLING_TIME_OFFSET

  # Intentionally, loudly assert. Point is to fail visibly and unignorably
  # during testing.
  if epoch >= 4 and slot mod SLOTS_PER_EPOCH > SETTLING_TIME_OFFSET:
    let finalizedEpoch = node.dag.finalizedHead.slot.epoch()
    # Finalization rule 234, that has the most lag slots among the cases, sets
    # state.finalized_checkpoint = old_previous_justified_checkpoint.epoch + 3
    # and then state.slot gets incremented, to increase the maximum offset, if
    # finalization occurs every slot, to 4 slots vs scheduledSlot.
    doAssert finalizedEpoch + 4 >= epoch

proc onSlotStart(
    node: BeaconNode, wallTime: BeaconTime, lastSlot: Slot
): Future[bool] {.async.} =
  ## Called at the beginning of a slot - usually every slot, but sometimes might
  ## skip a few in case we're running late.
  ## wallTime: current system time - we will strive to perform all duties up
  ##           to this point in time
  ## lastSlot: the last slot that we successfully processed, so we know where to
  ##           start work from - there might be jumps if processing is delayed
  let
    # The slot we should be at, according to the clock
    wallSlot = wallTime.slotOrZero
    # If everything was working perfectly, the slot that we should be processing
    expectedSlot = lastSlot + 1
    finalizedEpoch = node.dag.finalizedHead.blck.slot.epoch()
    delay = wallTime - expectedSlot.start_beacon_time()

  node.processingDelay = Opt.some(nanoseconds(delay.nanoseconds))

  block:
    logScope:
      slot = shortLog(wallSlot)
      epoch = shortLog(wallSlot.epoch)
      sync = node.syncStatus(wallSlot)
      peers = len(node.network.peerPool)
      head = shortLog(node.dag.head)
      finalized = shortLog(getStateField(node.dag.headState, finalized_checkpoint))
      delay = shortLog(delay)
    let nextConsensusForkDescription = node.formatNextConsensusFork()
    if nextConsensusForkDescription.isNone:
      info "Slot start"
    else:
      info "Slot start", nextFork = nextConsensusForkDescription.get

  # Check before any re-scheduling of onSlotStart()
  if checkIfShouldStopAtEpoch(wallSlot, node.config.stopAtEpoch):
    quit(0)

  when defined(windows):
    if node.config.runAsService:
      reportServiceStatusSuccess()

  # TODO: metrics
  # beacon_slot.set wallSlot.toGaugeValue
  # beacon_current_epoch.set wallSlot.epoch.toGaugeValue

  # both non-negative, so difference can't overflow or underflow int64
  # finalization_delay.set(
  #   wallSlot.epoch.toGaugeValue - finalizedEpoch.toGaugeValue)

  if node.config.strictVerification:
    verifyFinalization(node, wallSlot)

  node.consensusManager[].updateHead(wallSlot)

  await node.handleValidatorDuties(lastSlot, wallSlot)

  await onSlotEnd(node, wallSlot)

  # https://github.com/ethereum/builder-specs/blob/v0.4.0/specs/bellatrix/validator.md#registration-dissemination
  # This specification suggests validators re-submit to builder software every
  # `EPOCHS_PER_VALIDATOR_REGISTRATION_SUBMISSION` epochs.
  if wallSlot.is_epoch and
      wallSlot.epoch mod EPOCHS_PER_VALIDATOR_REGISTRATION_SUBMISSION == 0:
    asyncSpawn node.registerValidators(wallSlot.epoch)

  return false

proc startBackfillTask(node: BeaconNode) {.async.} =
  while node.dag.needsBackfill:
    if not node.syncManager.inProgress:
      # Only start the backfiller if it's needed _and_ head sync has completed -
      # if we lose sync after having synced head, we could stop the backfilller,
      # but this should be a fringe case - might as well keep the logic simple for
      # now
      node.backfiller.start()
      return

    await sleepAsync(chronos.seconds(2))

proc onSecond(node: BeaconNode, time: Moment) =
  # Nim GC metrics (for the main thread)

  # TODO: Collect metrics
  # updateThreadMetrics()

  if node.config.stopAtSyncedEpoch != 0 and
      node.dag.head.slot.epoch >= node.config.stopAtSyncedEpoch:
    notice "Shutting down after having reached the target synced epoch"
    bnStatus = BeaconNodeStatus.Stopping

proc runOnSecondLoop(node: BeaconNode) {.async.} =
  const
    sleepTime = chronos.seconds(1)
    nanosecondsIn1s = float(sleepTime.nanoseconds)
  while true:
    let start = chronos.now(chronos.Moment)
    await chronos.sleepAsync(sleepTime)
    let afterSleep = chronos.now(chronos.Moment)
    let sleepTime = afterSleep - start
    node.onSecond(start)
    let finished = chronos.now(chronos.Moment)
    let processingTime = finished - afterSleep

    # TODO: metrics
    # ticks_delay.set(sleepTime.nanoseconds.float / nanosecondsIn1s)
    trace "onSecond task completed", sleepTime, processingTime

proc run(node: BeaconNode) {.raises: [CatchableError].} =
  bnStatus = BeaconNodeStatus.Running

  if not isNil(node.restServer):
    node.restServer.installRestHandlers(node)
    node.restServer.start()

  if not isNil(node.keymanagerServer):
    doAssert not isNil(node.keymanagerHost)
    node.keymanagerServer.router.installKeymanagerHandlers(node.keymanagerHost[])
    if node.keymanagerServer != node.restServer:
      node.keymanagerServer.start()

  let
    wallTime = node.beaconClock.now()
    wallSlot = wallTime.slotOrZero()

  # node.startLightClient()
  node.requestManager.start()
  node.syncManager.start()

  if node.dag.needsBackfill():
    asyncSpawn node.startBackfillTask()

  waitFor node.localUpdateGossipStatus(wallSlot)

  for web3signerUrl in node.config.web3SignerUrls:
    # TODO
    # The current strategy polls all remote signers independently
    # from each other which may lead to some race conditions of
    # validators are migrated from one signer to another
    # (because the updates to our validator pool are not atomic).
    # Consider using different strategies that would detect such
    # race conditions.
    asyncSpawn node.pollForDynamicValidators(
      web3signerUrl, node.config.web3signerUpdateInterval
    )

  asyncSpawn runSlotLoop(node, wallTime, onSlotStart)
  asyncSpawn runOnSecondLoop(node)
  asyncSpawn runQueueProcessingLoop(node.blockProcessor)
  asyncSpawn runKeystoreCachePruningLoop(node.keystoreCache)

  # main event loop
  while bnStatus == BeaconNodeStatus.Running:
    poll() # if poll fails, the network is broken

  # time to say goodbye
  node.stop()

proc start*(node: BeaconNode) {.raises: [CatchableError].} =
  let
    head = node.dag.head
    finalizedHead = node.dag.finalizedHead
    genesisTime = node.beaconClock.fromNow(start_beacon_time(Slot 0))

  notice "Starting beacon node",
    version = fullVersionStr,
    nimVersion = NimVersion,
    enr = node.network.announcedENR.toURI,
    peerId = $node.network.switch.peerInfo.peerId,
    timeSinceFinalization =
      node.beaconClock.now() - finalizedHead.slot.start_beacon_time(),
    head = shortLog(head),
    justified =
      shortLog(getStateField(node.dag.headState, current_justified_checkpoint)),
    finalized = shortLog(getStateField(node.dag.headState, finalized_checkpoint)),
    finalizedHead = shortLog(finalizedHead),
    SLOTS_PER_EPOCH,
    SECONDS_PER_SLOT,
    SPEC_VERSION,
    dataDir = node.config.dataDir.string,
    validators = node.attachedValidators[].count

  if genesisTime.inFuture:
    notice "Waiting for genesis", genesisIn = genesisTime.offset

  waitFor node.initializeNetworking()

  node.elManager.start()
  node.run()

## runs beacon node
## adapted from nimbus-eth2
proc doRunBeaconNode(
    config: var BeaconNodeConf, rng: ref HmacDrbgContext
) {.raises: [CatchableError].} =
  # TODO: Define this varaibles somewhere
  info "Launching beacon node",
    version = fullVersionStr,
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

  #TODO: figure out the comment on createPidFile
  # createPidFile(config.dataDir.string / "beacon_node.pid")

  config.createDumpDirs()

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

  # Nim GC metrics (for the main thread) will be collected in onSecond(), but
  # we disable piggy-backing on other metrics here.

  #TODO: reactivate once we have metrics defined
  # setSystemMetricsAutomaticUpdate(false)

  # There are no managed event loops in here, to do a graceful shutdown, but
  # letting the default Ctrl+C handler exit is safe, since we only read from
  # the db.
  let metadata = config.loadEth2Network()

  # Updating the config based on the metadata certainly is not beautiful but it
  # works
  for node in metadata.bootstrapNodes:
    config.bootstrapNodes.add node

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except Exception as exc:
        raiseAssert exc.msg
        # shouldn't happen
    notice "Shutting down after having received SIGINT"
    bnStatus = BeaconNodeStatus.Stopping

  try:
    setControlCHook(controlCHandler)
  except Exception as exc: # TODO Exception
    warn "Cannot set ctrl-c handler", msg = exc.msg

  # equivalent SIGTERM handler
  when defined(posix):
    proc SIGTERMHandler(signal: cint) {.noconv.} =
      notice "Shutting down after having received SIGTERM"
      bnStatus = BeaconNodeStatus.Stopping

    c_signal(ansi_c.SIGTERM, SIGTERMHandler)

  block:
    let res =
      if config.trustedSetupFile.isNone:
        conf.loadKzgTrustedSetup()
      else:
        conf.loadKzgTrustedSetup(config.trustedSetupFile.get)
    if res.isErr():
      raiseAssert res.error()

  let node = waitFor BeaconNode.initBeaconNode(rng, config, metadata)

  if bnStatus == BeaconNodeStatus.Stopping:
    return

  when not defined(windows):
    # This status bar can lock a Windows terminal emulator, blocking the whole
    # event loop (seen on Windows 10, with a default MSYS2 terminal).
    initStatusBar(node)

  if node.nickname != "":
    dynamicLogScope(node = node.nickname):
      node.start()
  else:
    node.start()

## --end copy paste file from nimbus-eth2/nimbus_beacon_node.nim

proc handleStartingOption(config: var BeaconNodeConf) {.raises: [CatchableError].} =
  let rng = HmacDrbgContext.new()

  # More options can be added, might be out of scope given that they exist in eth2
  case config.cmd
  of BNSStartUpCmd.noCommand:
    doRunBeaconNode(config, rng)
  of BNSStartUpCmd.trustedNodeSync:
    if config.blockId.isSome():
      error "--blockId option has been removed - use --state-id instead!"
      quit 1

    let
      metadata = loadEth2Network(config)
      db = BeaconChainDB.new(config.databaseDir, metadata.cfg, inMemory = false)
      genesisState = waitFor fetchGenesisState(metadata)
    waitFor db.doRunTrustedNodeSync(
      config.databaseDir, config.eraDir, config.trustedNodeUrl, config.stateId,
      config.lcTrustedBlockRoot, config.backfillBlocks, config.reindex,
      config.downloadDepositSnapshot, genesisState,
    )
    db.close()

## Consensus wrapper
proc consensusWrapper*(parameters: TaskParameters) {.raises: [CatchableError].} =
  var config = parameters.beaconNodeConfigs
  try:
    doRunBeaconNode(config, rng)
  except CatchableError as e:
    fatal "error", message = e.msg
    isShutDownRequired.store(true)

  isShutDownRequired.store(true)
  warn "\tExiting consensus wrapper"
