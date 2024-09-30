# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  eth/trie/trie_defs,
  ../core/casper,
  ../db/[core_db, ledger, storage_types],
  ../utils/[utils, ec_recover],
  ".."/[constants, errors],
  "."/[chain_config, evmforks, genesis, hardforks]

export
  chain_config,
  core_db,
  constants,
  errors,
  evmforks,
  hardforks,
  genesis,
  utils

type
  SyncProgress = object
    start  : BlockNumber
    current: BlockNumber
    highest: BlockNumber

  SyncState* = enum
    Waiting
    Syncing
    Synced

  SyncReqNewHeadCB* = proc(header: BlockHeader) {.gcsafe, raises: [].}
    ## Update head for syncing

  SyncFinalisedBlockHashCB* = proc(hash: Hash256) {.gcsafe, raises: [].}
    ## Ditto

  NotifyBadBlockCB* = proc(invalid, origin: BlockHeader) {.gcsafe, raises: [].}
    ## Notify engine-API of encountered bad block

  CommonRef* = ref object
    # all purpose storage
    db: CoreDbRef

    # block chain config
    config: ChainConfig

    # cache of genesis
    genesisHash: KeccakHash
    genesisHeader: BlockHeader

    # map block number and ttd and time to
    # HardFork
    forkTransitionTable: ForkTransitionTable

    # Eth wire protocol need this
    forkIdCalculator: ForkIdCalculator
    networkId: NetworkId

    # synchronizer need this
    syncProgress: SyncProgress

    syncState: SyncState

    # one of POW/POS, updated after calling `hardForkTransition`
    consensusType: ConsensusType

    syncReqNewHead: SyncReqNewHeadCB
      ## Call back function for the sync processor. This function stages
      ## the arguent header to a private aerea for subsequent processing.

    syncFinalisedBlockHash: SyncFinalisedBlockHashCB
      ## Call back function for a sync processor that returns the canonical
      ## header.

    notifyBadBlock: NotifyBadBlockCB
      ## Allow synchronizer to inform engine-API of bad encountered during sync
      ## progress

    startOfHistory: Hash256
      ## This setting is needed for resuming blockwise syncying after
      ## installing a snapshot pivot. The default value for this field is
      ## `GENESIS_PARENT_HASH` to start at the very beginning.

    pos: CasperRef
      ## Proof Of Stake descriptor

    pruneHistory: bool
      ## Must not not set for a full node, might go away some time

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

func hardForkTransition*(
  com: CommonRef, forkDeterminer: ForkDeterminationInfo)
  {.gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

func consensusTransition(com: CommonRef, fork: HardFork) =
  if fork >= MergeFork:
    com.consensusType = ConsensusType.POS
  else:
    # restore consensus type to original config
    # this could happen during reorg
    com.consensusType = com.config.consensusType

func setForkId(com: CommonRef, genesis: BlockHeader) =
  com.genesisHash = genesis.blockHash
  let genesisCRC = crc32(0, com.genesisHash.data)
  com.forkIdCalculator = initForkIdCalculator(
    com.forkTransitionTable,
    genesisCRC,
    genesis.timestamp.uint64)

func daoCheck(conf: ChainConfig) =
  if not conf.daoForkSupport or conf.daoForkBlock.isNone:
    conf.daoForkBlock = conf.homesteadBlock

  if conf.daoForkSupport and conf.daoForkBlock.isNone:
    conf.daoForkBlock = conf.homesteadBlock

proc initializeDb(com: CommonRef) =
  let kvt = com.db.ctx.getKvt()
  proc contains(kvt: CoreDbKvtRef; key: openArray[byte]): bool =
    kvt.hasKeyRc(key).expect "valid bool"
  if canonicalHeadHashKey().toOpenArray notin kvt:
    info "Writing genesis to DB"
    doAssert(com.genesisHeader.number == 0.BlockNumber,
      "can't commit genesis block with number > 0")
    doAssert(com.db.persistHeader(com.genesisHeader,
      com.consensusType == ConsensusType.POS,
      startOfHistory=com.genesisHeader.parentHash),
      "can persist genesis header")
    doAssert(canonicalHeadHashKey().toOpenArray in kvt)

  # The database must at least contain the base and head pointers - the base
  # is implicitly considered finalized
  let
    baseNum = com.db.getSavedStateBlockNumber()
    base =
      try:
        com.db.getBlockHeader(baseNum)
      except BlockNotFound as exc:
        fatal "Cannot load base block header",
          baseNum, err = exc.msg
        quit 1
    finalized =
      try:
        com.db.finalizedHeader()
      except BlockNotFound:
        debug "No finalized block stored in database, reverting to base"
        base
    head =
      try:
        com.db.getCanonicalHead()
      except EVMError as exc:
        fatal "Cannot load canonical block header",
          err = exc.msg
        quit 1

  info "Database initialized",
    base = (base.blockHash, base.number),
    finalized = (finalized.blockHash, finalized.number),
    head = (head.blockHash, head.number)

proc init(com         : CommonRef,
          db          : CoreDbRef,
          networkId   : NetworkId,
          config      : ChainConfig,
          genesis     : Genesis,
          pruneHistory: bool,
            ) {.gcsafe, raises: [CatchableError].} =

  config.daoCheck()

  com.db          = db
  com.config      = config
  com.forkTransitionTable = config.toForkTransitionTable()
  com.networkId   = networkId
  com.syncProgress= SyncProgress()
  com.syncState   = Waiting
  com.pruneHistory= pruneHistory
  com.pos = CasperRef.new

  # com.consensusType
  # is set by hardForkTransition.
  # set it before creating genesis block
  # TD need to be some(0.u256) because it can be the genesis
  # already at the MergeFork
  const TimeZero = EthTime(0)

  # com.forkIdCalculator and com.genesisHash are set
  # by setForkId
  if genesis.isNil.not:
    let
      forkDeterminer = ForkDeterminationInfo(
        number: 0.BlockNumber,
        td: Opt.some(0.u256),
        time: Opt.some(genesis.timestamp)
      )
      fork = toHardFork(com.forkTransitionTable, forkDeterminer)

    com.consensusTransition(fork)

    # Must not overwrite the global state on the single state DB
    if not db.getBlockHeader(0.BlockNumber, com.genesisHeader):
      com.genesisHeader = toGenesisHeader(genesis,
        fork, com.db)

    com.setForkId(com.genesisHeader)
    com.pos.timestamp = genesis.timestamp
  else:
    com.hardForkTransition(ForkDeterminationInfo(
      number: 0.BlockNumber,
      td: Opt.some(0.u256),
      time: Opt.some(TimeZero)
    ))

  # By default, history begins at genesis.
  com.startOfHistory = GENESIS_PARENT_HASH

  com.initializeDb()

proc getTd(com: CommonRef, blockHash: Hash256): Opt[DifficultyInt] =
  var td: DifficultyInt
  if not com.db.getTd(blockHash, td):
    # TODO: Is this really ok?
    Opt.none(DifficultyInt)
  else:
    Opt.some(td)

func needTdForHardForkDetermination(com: CommonRef): bool =
  let t = com.forkTransitionTable.mergeForkTransitionThreshold
  t.ttdPassed.isNone and t.number.isNone and t.ttd.isSome

proc getTdIfNecessary(com: CommonRef, blockHash: Hash256): Opt[DifficultyInt] =
  if needTdForHardForkDetermination(com):
    getTd(com, blockHash)
  else:
    Opt.none(DifficultyInt)

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc new*(
    _: type CommonRef;
    db: CoreDbRef;
    networkId: NetworkId = MainNet;
    params = networkParams(MainNet);
    pruneHistory = false;
      ): CommonRef
      {.gcsafe, raises: [CatchableError].} =

  ## If genesis data is present, the forkIds will be initialized
  ## empty data base also initialized with genesis block
  new(result)
  result.init(
    db,
    networkId,
    params.config,
    params.genesis,
    pruneHistory)

proc new*(
    _: type CommonRef;
    db: CoreDbRef;
    config: ChainConfig;
    networkId: NetworkId = MainNet;
    pruneHistory = false;
      ): CommonRef
      {.gcsafe, raises: [CatchableError].} =

  ## There is no genesis data present
  ## Mainly used for testing without genesis
  new(result)
  result.init(
    db,
    networkId,
    config,
    nil,
    pruneHistory)

func clone*(com: CommonRef, db: CoreDbRef): CommonRef =
  ## clone but replace the db
  ## used in EVM tracer whose db is CaptureDB
  CommonRef(
    db           : db,
    config       : com.config,
    forkTransitionTable: com.forkTransitionTable,
    forkIdCalculator: com.forkIdCalculator,
    genesisHash  : com.genesisHash,
    genesisHeader: com.genesisHeader,
    syncProgress : com.syncProgress,
    networkId    : com.networkId,
    consensusType: com.consensusType,
    pos          : com.pos,
    pruneHistory : com.pruneHistory)

func clone*(com: CommonRef): CommonRef =
  com.clone(com.db)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func toHardFork*(
    com: CommonRef, forkDeterminer: ForkDeterminationInfo): HardFork =
  toHardFork(com.forkTransitionTable, forkDeterminer)

func hardForkTransition(
    com: CommonRef, forkDeterminer: ForkDeterminationInfo) =
  ## When consensus type already transitioned to POS,
  ## the storage can choose not to store TD anymore,
  ## at that time, TD is no longer needed to find a fork
  ## TD only needed during transition from POW to POS.
  ## Same thing happen before London block, TD can be ignored.

  let fork = com.toHardFork(forkDeterminer)
  com.consensusTransition(fork)

func hardForkTransition*(
    com: CommonRef,
    number: BlockNumber,
    td: Opt[DifficultyInt],
    time: Opt[EthTime]) =
  com.hardForkTransition(ForkDeterminationInfo(
    number: number, time: time, td: td))

proc hardForkTransition*(
    com: CommonRef,
    parentHash: Hash256,
    number: BlockNumber,
    time: Opt[EthTime]) =
  com.hardForkTransition(number, getTdIfNecessary(com, parentHash), time)

proc hardForkTransition*(
    com: CommonRef, header: BlockHeader)
    {.gcsafe, raises: [].} =
  com.hardForkTransition(
    header.parentHash, header.number, Opt.some(header.timestamp))

func toEVMFork*(com: CommonRef, forkDeterminer: ForkDeterminationInfo): EVMFork =
  ## similar to toFork, but produce EVMFork
  let fork = com.toHardFork(forkDeterminer)
  ToEVMFork[fork]

func isSpuriousOrLater*(com: CommonRef, number: BlockNumber): bool =
  com.toHardFork(number.forkDeterminationInfo) >= Spurious

func isByzantiumOrLater*(com: CommonRef, number: BlockNumber): bool =
  com.toHardFork(number.forkDeterminationInfo) >= Byzantium

func isLondonOrLater*(com: CommonRef, number: BlockNumber): bool =
  # TODO: Fixme, use only London comparator
  com.toHardFork(number.forkDeterminationInfo) >= London

func forkId*(com: CommonRef, head, time: uint64): ForkID {.gcsafe.} =
  ## EIP 2364/2124
  com.forkIdCalculator.newID(head, time)

func forkId*(com: CommonRef, head: BlockNumber, time: EthTime): ForkID {.gcsafe.} =
  ## EIP 2364/2124
  com.forkIdCalculator.newID(head, time.uint64)

func isEIP155*(com: CommonRef, number: BlockNumber): bool =
  com.config.eip155Block.isSome and number >= com.config.eip155Block.get

proc isBlockAfterTtd*(com: CommonRef, header: BlockHeader): bool =
  if com.config.terminalTotalDifficulty.isNone:
    return false

  let
    ttd = com.config.terminalTotalDifficulty.get()
    ptd = com.db.getScore(header.parentHash).valueOr:
      return false
    td  = ptd + header.difficulty
  ptd >= ttd and td >= ttd

func isShanghaiOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.shanghaiTime.isSome and t >= com.config.shanghaiTime.get

func isCancunOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.cancunTime.isSome and t >= com.config.cancunTime.get

func isPragueOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.pragueTime.isSome and t >= com.config.pragueTime.get

proc consensus*(com: CommonRef, header: BlockHeader): ConsensusType =
  if com.isBlockAfterTtd(header):
    return ConsensusType.POS

  return com.config.consensusType

proc syncReqNewHead*(com: CommonRef; header: BlockHeader)
    {.gcsafe, raises: [].} =
  ## Used by RPC updater
  if not com.syncReqNewHead.isNil:
    com.syncReqNewHead(header)

func haveSyncFinalisedBlockHash*(com: CommonRef): bool =
  not com.syncFinalisedBlockHash.isNil

proc syncFinalisedBlockHash*(com: CommonRef; hash: Hash256) =
  ## Used by RPC updater
  if not com.syncFinalisedBlockHash.isNil:
    com.syncFinalisedBlockHash(hash)

proc notifyBadBlock*(com: CommonRef; invalid, origin: BlockHeader)
    {.gcsafe, raises: [].} =

  if not com.notifyBadBlock.isNil:
    com.notifyBadBlock(invalid, origin)

# ------------------------------------------------------------------------------
# Getters
# ------------------------------------------------------------------------------

func startOfHistory*(com: CommonRef): Hash256 =
  ## Getter
  com.startOfHistory

func pos*(com: CommonRef): CasperRef =
  ## Getter
  com.pos

func db*(com: CommonRef): CoreDbRef =
  com.db

func consensus*(com: CommonRef): ConsensusType =
  com.consensusType

func eip150Block*(com: CommonRef): Opt[BlockNumber] =
  com.config.eip150Block

func eip150Hash*(com: CommonRef): Hash256 =
  com.config.eip150Hash

func daoForkBlock*(com: CommonRef): Opt[BlockNumber] =
  com.config.daoForkBlock

func daoForkSupport*(com: CommonRef): bool =
  com.config.daoForkSupport

func ttd*(com: CommonRef): Opt[DifficultyInt] =
  com.config.terminalTotalDifficulty

func ttdPassed*(com: CommonRef): bool =
  com.config.terminalTotalDifficultyPassed.get(false)

func pruneHistory*(com: CommonRef): bool =
  com.pruneHistory

# always remember ChainId and NetworkId
# are two distinct things that often got mixed
# because some client do not make distinction
# between them.
# And popular networks such as MainNet
# add more confusion to this
# by not making a distinction in their value.
func chainId*(com: CommonRef): ChainId =
  com.config.chainId

func networkId*(com: CommonRef): NetworkId =
  com.networkId

func genesisHash*(com: CommonRef): Hash256 =
  ## Getter
  com.genesisHash

func genesisHeader*(com: CommonRef): BlockHeader =
  ## Getter
  com.genesisHeader

func syncStart*(com: CommonRef): BlockNumber =
  com.syncProgress.start

func syncCurrent*(com: CommonRef): BlockNumber =
  com.syncProgress.current

func syncHighest*(com: CommonRef): BlockNumber =
  com.syncProgress.highest

func syncState*(com: CommonRef): SyncState =
  com.syncState

# ------------------------------------------------------------------------------
# Setters
# ------------------------------------------------------------------------------

func `syncStart=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.start = number

func `syncCurrent=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.current = number

func `syncHighest=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.highest = number

func `syncState=`*(com: CommonRef, state: SyncState) =
  com.syncState = state

func `startOfHistory=`*(com: CommonRef, val: Hash256) =
  ## Setter
  com.startOfHistory = val

func setTTD*(com: CommonRef, ttd: Opt[DifficultyInt]) =
  ## useful for testing
  com.config.terminalTotalDifficulty = ttd
  # rebuild the MergeFork piece of the forkTransitionTable
  com.forkTransitionTable.mergeForkTransitionThreshold = com.config.mergeForkTransitionThreshold

func `syncReqNewHead=`*(com: CommonRef; cb: SyncReqNewHeadCB) =
  ## Activate or reset a call back handler for syncing.
  com.syncReqNewHead = cb

func `syncFinalisedBlockHash=`*(com: CommonRef; cb: SyncFinalisedBlockHashCB) =
  ## Activate or reset a call back handler for syncing.
  com.syncFinalisedBlockHash = cb

func `notifyBadBlock=`*(com: CommonRef; cb: NotifyBadBlockCB) =
  ## Activate or reset a call back handler for bad block notification.
  com.notifyBadBlock = cb

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
