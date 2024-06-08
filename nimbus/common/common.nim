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
  std/[options],
  chronicles,
  eth/trie/trie_defs,
  ../core/[pow, casper],
  ../db/[core_db, ledger, storage_types],
  ../utils/[utils, ec_recover],
  ".."/[constants, errors],
  "."/[chain_config, evmforks, genesis, hardforks]

export
  chain_config,
  core_db,
  constants,
  errors,
  options,
  evmforks,
  hardforks,
  genesis,
  utils

type
  SyncProgress = object
    start  : BlockNumber
    current: BlockNumber
    highest: BlockNumber

  SyncReqNewHeadCB* = proc(header: BlockHeader) {.gcsafe, raises: [].}
    ## Update head for syncing

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

    # current hard fork, updated after calling `hardForkTransition`
    currentFork: HardFork

    # one of POW/POS, updated after calling `hardForkTransition`
    consensusType: ConsensusType

    syncReqNewHead: SyncReqNewHeadCB
      ## Call back function for the sync processor. This function stages
      ## the arguent header to a private aerea for subsequent processing.

    notifyBadBlock: NotifyBadBlockCB
      ## Allow synchronizer to inform engine-API of bad encountered during sync
      ## progress

    startOfHistory: Hash256
      ## This setting is needed for resuming blockwise syncying after
      ## installing a snapshot pivot. The default value for this field is
      ## `GENESIS_PARENT_HASH` to start at the very beginning.

    pow: PowRef
      ## Wrapper around `hashimotoLight()` and lookup cache

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
  com.pruneHistory= pruneHistory

  # Always initialise the PoW epoch cache even though it migh no be used
  com.pow = PowRef.new
  com.pos = CasperRef.new

  # com.currentFork and com.consensusType
  # is set by hardForkTransition.
  # set it before creating genesis block
  # TD need to be some(0.u256) because it can be the genesis
  # already at the MergeFork
  const TimeZero = EthTime(0)

  # com.forkIdCalculator and com.genesisHash are set
  # by setForkId
  if genesis.isNil.not:
    com.hardForkTransition(ForkDeterminationInfo(
      blockNumber: 0.toBlockNumber,
      td: Opt.some(0.u256),
      time: Opt.some(genesis.timestamp)
    ))

    # Must not overwrite the global state on the single state DB
    if not db.getBlockHeader(0.toBlockNumber, com.genesisHeader):
      com.genesisHeader = toGenesisHeader(genesis,
        com.currentFork, com.db)

    com.setForkId(com.genesisHeader)
    com.pos.timestamp = genesis.timestamp
  else:
    com.hardForkTransition(ForkDeterminationInfo(
      blockNumber: 0.toBlockNumber,
      td: Opt.some(0.u256),
      time: Opt.some(TimeZero)
    ))

  # By default, history begins at genesis.
  com.startOfHistory = GENESIS_PARENT_HASH

proc getTd(com: CommonRef, blockHash: Hash256): Opt[DifficultyInt] =
  var td: DifficultyInt
  if not com.db.getTd(blockHash, td):
    # TODO: Is this really ok?
    Opt.none(DifficultyInt)
  else:
    Opt.some(td)

func needTdForHardForkDetermination(com: CommonRef): bool =
  let t = com.forkTransitionTable.mergeForkTransitionThreshold
  t.ttdPassed.isNone and t.blockNumber.isNone and t.ttd.isSome

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
    currentFork  : com.currentFork,
    consensusType: com.consensusType,
    pow          : com.pow,
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
  com.currentFork = fork
  com.consensusTransition(fork)

func hardForkTransition*(
    com: CommonRef,
    number: BlockNumber,
    td: Opt[DifficultyInt],
    time: Opt[EthTime]) =
  com.hardForkTransition(ForkDeterminationInfo(
    blockNumber: number, time: time, td: td))

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
    header.parentHash, header.blockNumber, Opt.some(header.timestamp))

func toEVMFork*(com: CommonRef, forkDeterminer: ForkDeterminationInfo): EVMFork =
  ## similar to toFork, but produce EVMFork
  let fork = com.toHardFork(forkDeterminer)
  ToEVMFork[fork]

func toEVMFork*(com: CommonRef): EVMFork =
  ToEVMFork[com.currentFork]

func isLondon*(com: CommonRef, number: BlockNumber): bool =
  # TODO: Fixme, use only London comparator
  com.toHardFork(number.forkDeterminationInfo) >= London

func isLondon*(com: CommonRef, number: BlockNumber, timestamp: EthTime): bool =
  # TODO: Fixme, use only London comparator
  com.toHardFork(forkDeterminationInfo(number, timestamp)) >= London

func forkGTE*(com: CommonRef, fork: HardFork): bool =
  com.currentFork >= fork

# TODO: move this consensus code to where it belongs
func minerAddress*(com: CommonRef; header: BlockHeader): EthAddress =
  # POW and POS return header.coinbase
  return header.coinbase

func forkId*(com: CommonRef, head, time: uint64): ForkID {.gcsafe.} =
  ## EIP 2364/2124
  com.forkIdCalculator.newID(head, time)

func forkId*(com: CommonRef, head: BlockNumber, time: EthTime): ForkID {.gcsafe.} =
  ## EIP 2364/2124
  com.forkIdCalculator.newID(head.truncate(uint64), time.uint64)

func isEIP155*(com: CommonRef, number: BlockNumber): bool =
  com.config.eip155Block.isSome and number >= com.config.eip155Block.get

proc isBlockAfterTtd*(com: CommonRef, header: BlockHeader): bool
                      {.gcsafe, raises: [CatchableError].} =
  if com.config.terminalTotalDifficulty.isNone:
    return false

  let
    ttd = com.config.terminalTotalDifficulty.get()
    ptd = com.db.getScore(header.parentHash)
    td  = ptd + header.difficulty
  ptd >= ttd and td >= ttd

func isShanghaiOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.shanghaiTime.isSome and t >= com.config.shanghaiTime.get

func isCancunOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.cancunTime.isSome and t >= com.config.cancunTime.get

func isPragueOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.pragueTime.isSome and t >= com.config.pragueTime.get

proc consensus*(com: CommonRef, header: BlockHeader): ConsensusType
                {.gcsafe, raises: [CatchableError].} =
  if com.isBlockAfterTtd(header):
    return ConsensusType.POS

  return com.config.consensusType

proc initializeEmptyDb*(com: CommonRef)
    {.gcsafe, raises: [CatchableError].} =
  let kvt = com.db.newKvt()
  proc contains(kvt: CoreDxKvtRef; key: openArray[byte]): bool =
    kvt.hasKey(key).expect "valid bool"
  if canonicalHeadHashKey().toOpenArray notin kvt:
    info "Writing genesis to DB"
    doAssert(com.genesisHeader.blockNumber.isZero,
      "can't commit genesis block with number > 0")
    discard com.db.persistHeaderToDb(com.genesisHeader,
      com.consensusType == ConsensusType.POS)
    doAssert(canonicalHeadHashKey().toOpenArray in kvt)

proc syncReqNewHead*(com: CommonRef; header: BlockHeader)
    {.gcsafe, raises: [].} =
  ## Used by RPC to update the beacon head for snap sync
  if not com.syncReqNewHead.isNil:
    com.syncReqNewHead(header)

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

func pow*(com: CommonRef): PowRef =
  ## Getter
  com.pow

func pos*(com: CommonRef): CasperRef =
  ## Getter
  com.pos

func db*(com: CommonRef): CoreDbRef =
  com.db

func consensus*(com: CommonRef): ConsensusType =
  com.consensusType

func eip150Block*(com: CommonRef): Option[BlockNumber] =
  com.config.eip150Block

func eip150Hash*(com: CommonRef): Hash256 =
  com.config.eip150Hash

func daoForkBlock*(com: CommonRef): Option[BlockNumber] =
  com.config.daoForkBlock

func daoForkSupport*(com: CommonRef): bool =
  com.config.daoForkSupport

func ttd*(com: CommonRef): Option[DifficultyInt] =
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

func blockReward*(com: CommonRef): UInt256 =
  BlockRewards[com.currentFork]

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

# ------------------------------------------------------------------------------
# Setters
# ------------------------------------------------------------------------------

func `syncStart=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.start = number

func `syncCurrent=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.current = number

func `syncHighest=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.highest = number

func `startOfHistory=`*(com: CommonRef, val: Hash256) =
  ## Setter
  com.startOfHistory = val

func setTTD*(com: CommonRef, ttd: Option[DifficultyInt]) =
  ## useful for testing
  com.config.terminalTotalDifficulty = ttd
  # rebuild the MergeFork piece of the forkTransitionTable
  com.forkTransitionTable.mergeForkTransitionThreshold = com.config.mergeForkTransitionThreshold

func setFork*(com: CommonRef, fork: HardFork): HardFork =
  ## useful for testing
  result = com.currentFork
  com.currentFork = fork
  com.consensusTransition(fork)

func `syncReqNewHead=`*(com: CommonRef; cb: SyncReqNewHeadCB) =
  ## Activate or reset a call back handler for syncing.
  com.syncReqNewHead = cb

func `notifyBadBlock=`*(com: CommonRef; cb: NotifyBadBlockCB) =
  ## Activate or reset a call back handler for bad block notification.
  com.notifyBadBlock = cb

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
