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
  ../core/casper,
  ../db/[core_db, ledger, storage_types],
  ../utils/[utils],
  ".."/[constants, errors, version],
  "."/[chain_config, evmforks, genesis, hardforks],
  taskpools

export
  chain_config,
  core_db,
  constants,
  errors,
  evmforks,
  hardforks,
  genesis,
  utils,
  taskpools

type
  SyncProgress = object
    start  : BlockNumber
    current: BlockNumber
    highest: BlockNumber

  SyncState* = enum
    Waiting
    Syncing
    Synced

  SyncReqNewHeadCB* = proc(header: Header) {.gcsafe, raises: [].}
    ## Update head for syncing

  ReqBeaconSyncTargetCB* = proc(header: Header; finHash: Hash32) {.gcsafe, raises: [].}
    ## Ditto (for beacon sync)

  NotifyBadBlockCB* = proc(invalid, origin: Header) {.gcsafe, raises: [].}
    ## Notify engine-API of encountered bad block

  CommonRef* = ref object
    # all purpose storage
    db: CoreDbRef

    # block chain config
    config: ChainConfig

    # cache of genesis
    genesisHash: Hash32
    genesisHeader: Header

    # map block number and ttd and time to
    # HardFork
    forkTransitionTable: ForkTransitionTable

    # Eth wire protocol need this
    forkIdCalculator: ForkIdCalculator
    networkId: NetworkId

    # synchronizer need this
    syncProgress: SyncProgress

    syncState: SyncState

    syncReqNewHead: SyncReqNewHeadCB
      ## Call back function for the sync processor. This function stages
      ## the arguent header to a private aerea for subsequent processing.

    reqBeaconSyncTargetCB: ReqBeaconSyncTargetCB
      ## Call back function for a sync processor that returns the canonical
      ## header.

    notifyBadBlock: NotifyBadBlockCB
      ## Allow synchronizer to inform engine-API of bad encountered during sync
      ## progress

    startOfHistory: Hash32
      ## This setting is needed for resuming blockwise syncying after
      ## installing a snapshot pivot. The default value for this field is
      ## `GENESIS_PARENT_HASH` to start at the very beginning.

    pos: CasperRef
      ## Proof Of Stake descriptor

    pruneHistory: bool
      ## Must not not set for a full node, might go away some time

    extraData: string
      ## Value of extraData field when building a block

    gasLimit: uint64
      ## Desired gas limit when building a block

    taskpool*: Taskpool
      ## Shared task pool for offloading computation to other threads

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

func setForkId(com: CommonRef, genesis: Header) =
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
    info "Writing genesis to DB",
      blockHash = com.genesisHeader.rlpHash,
      stateRoot = com.genesisHeader.stateRoot,
      difficulty = com.genesisHeader.difficulty,
      gasLimit = com.genesisHeader.gasLimit,
      timestamp = com.genesisHeader.timestamp,
      nonce = com.genesisHeader.nonce
    doAssert(com.genesisHeader.number == 0.BlockNumber,
      "can't commit genesis block with number > 0")
    com.db.persistHeaderAndSetHead(com.genesisHeader,
      startOfHistory=com.genesisHeader.parentHash).
      expect("can persist genesis header")
    doAssert(canonicalHeadHashKey().toOpenArray in kvt)

  # The database must at least contain the base and head pointers - the base
  # is implicitly considered finalized
  let
    baseNum = com.db.getSavedStateBlockNumber()
    base = com.db.getBlockHeader(baseNum).valueOr:
      fatal "Cannot load base block header",
        baseNum, err = error
      quit 1
    finalized = com.db.finalizedHeader().valueOr:
      debug "No finalized block stored in database, reverting to base"
      base
    head = com.db.getCanonicalHead().valueOr:
      fatal "Cannot load canonical block header",
        err = error
      quit 1

  info "Database initialized",
    base = (base.blockHash, base.number),
    finalized = (finalized.blockHash, finalized.number),
    head = (head.blockHash, head.number)

proc init(com         : CommonRef,
          db          : CoreDbRef,
          taskpool    : Taskpool,
          networkId   : NetworkId,
          config      : ChainConfig,
          genesis     : Genesis,
          pruneHistory: bool) =

  config.daoCheck()

  com.db          = db
  com.config      = config
  com.forkTransitionTable = config.toForkTransitionTable()
  com.networkId   = networkId
  com.syncProgress= SyncProgress()
  com.syncState   = Waiting
  com.pruneHistory= pruneHistory
  com.pos         = CasperRef.new
  com.extraData   = ShortClientId
  com.taskpool    = taskpool
  com.gasLimit    = DEFAULT_GAS_LIMIT

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

    # Must not overwrite the global state on the single state DB
    com.genesisHeader = db.getBlockHeader(0.BlockNumber).valueOr:
      toGenesisHeader(genesis, fork, com.db)

    com.setForkId(com.genesisHeader)
    com.pos.timestamp = genesis.timestamp

  # By default, history begins at genesis.
  com.startOfHistory = GENESIS_PARENT_HASH

  com.initializeDb()

proc isBlockAfterTtd(com: CommonRef, header: Header): bool =
  if com.config.terminalTotalDifficulty.isNone:
    return false

  let
    ttd = com.config.terminalTotalDifficulty.get()
    ptd = com.db.getScore(header.parentHash).valueOr:
      return false
    td  = ptd + header.difficulty
  ptd >= ttd and td >= ttd

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc new*(
    _: type CommonRef;
    db: CoreDbRef;
    taskpool: Taskpool;
    networkId: NetworkId = MainNet;
    params = networkParams(MainNet);
    pruneHistory = false;
      ): CommonRef =

  ## If genesis data is present, the forkIds will be initialized
  ## empty data base also initialized with genesis block
  new(result)
  result.init(
    db,
    taskpool,
    networkId,
    params.config,
    params.genesis,
    pruneHistory)

proc new*(
    _: type CommonRef;
    db: CoreDbRef;
    taskpool: Taskpool;
    config: ChainConfig;
    networkId: NetworkId = MainNet;
    pruneHistory = false;
      ): CommonRef =

  ## There is no genesis data present
  ## Mainly used for testing without genesis
  new(result)
  result.init(
    db,
    taskpool,
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

func isShanghaiOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.shanghaiTime.isSome and t >= com.config.shanghaiTime.get

func isCancunOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.cancunTime.isSome and t >= com.config.cancunTime.get

func isPragueOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.pragueTime.isSome and t >= com.config.pragueTime.get

proc proofOfStake*(com: CommonRef, header: Header): bool =
  if com.config.posBlock.isSome:
    # see comments of posBlock in common/hardforks.nim
    header.number >= com.config.posBlock.get
  elif com.config.mergeNetsplitBlock.isSome:
    header.number >= com.config.mergeNetsplitBlock.get
  else:
    # This costly check is only executed from test suite
    com.isBlockAfterTtd(header)

func depositContractAddress*(com: CommonRef): Address =
  com.config.depositContractAddress.get(default(Address))

proc syncReqNewHead*(com: CommonRef; header: Header)
    {.gcsafe, raises: [].} =
  ## Used by RPC updater
  if not com.syncReqNewHead.isNil:
    com.syncReqNewHead(header)

proc reqBeaconSyncTargetCB*(com: CommonRef; header: Header; finHash: Hash32) =
  ## Used by RPC updater
  if not com.reqBeaconSyncTargetCB.isNil:
    com.reqBeaconSyncTargetCB(header, finHash)

proc notifyBadBlock*(com: CommonRef; invalid, origin: Header)
    {.gcsafe, raises: [].} =

  if not com.notifyBadBlock.isNil:
    com.notifyBadBlock(invalid, origin)

# ------------------------------------------------------------------------------
# Getters
# ------------------------------------------------------------------------------

func startOfHistory*(com: CommonRef): Hash32 =
  ## Getter
  com.startOfHistory

func pos*(com: CommonRef): CasperRef =
  ## Getter
  com.pos

func db*(com: CommonRef): CoreDbRef =
  com.db

func eip150Block*(com: CommonRef): Opt[BlockNumber] =
  com.config.eip150Block

func eip150Hash*(com: CommonRef): Hash32 =
  com.config.eip150Hash

func daoForkBlock*(com: CommonRef): Opt[BlockNumber] =
  com.config.daoForkBlock

func daoForkSupport*(com: CommonRef): bool =
  com.config.daoForkSupport

func ttd*(com: CommonRef): Opt[DifficultyInt] =
  com.config.terminalTotalDifficulty

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

func genesisHash*(com: CommonRef): Hash32 =
  ## Getter
  com.genesisHash

func genesisHeader*(com: CommonRef): Header =
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

func extraData*(com: CommonRef): string =
  com.extraData

func gasLimit*(com: CommonRef): uint64 =
  com.gasLimit

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

func `startOfHistory=`*(com: CommonRef, val: Hash32) =
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

func `reqBeaconSyncTarget=`*(com: CommonRef; cb: ReqBeaconSyncTargetCB) =
  ## Activate or reset a call back handler for syncing.
  com.reqBeaconSyncTargetCB = cb

func `notifyBadBlock=`*(com: CommonRef; cb: NotifyBadBlockCB) =
  ## Activate or reset a call back handler for bad block notification.
  com.notifyBadBlock = cb

func `extraData=`*(com: CommonRef, val: string) =
  com.extraData = val

func `gasLimit=`*(com: CommonRef, val: uint64) =
  if val < GAS_LIMIT_MINIMUM:
    com.gasLimit = GAS_LIMIT_MINIMUM
  elif val > GAS_LIMIT_MAXIMUM:
    com.gasLimit = GAS_LIMIT_MAXIMUM
  else:
    com.gasLimit = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
