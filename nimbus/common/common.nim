# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
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
  ../core/[pow, clique, casper],
  ../db/[core_db, storage_types],
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

  CommonRef* = ref object
    # all purpose storage
    db: CoreDbRef

    # prune underlying state db?
    pruneTrie: bool

    # block chain config
    config: ChainConfig

    # cache of genesis
    genesisHash: KeccakHash
    genesisHeader: BlockHeader

    # map block number and ttd and time to
    # HardFork
    forkTransitionTable: ForkTransitionTable

    # Eth wire protocol need this
    forkIds: array[HardFork, ForkID]
    networkId: NetworkId

    # synchronizer need this
    syncProgress: SyncProgress

    # current hard fork, updated after calling `hardForkTransition`
    currentFork: HardFork

    # one of POW/POA/POS, updated after calling `hardForkTransition`
    consensusType: ConsensusType

    syncReqNewHead: SyncReqNewHeadCB
      ## Call back function for the sync processor. This function stages
      ## the arguent header to a private aerea for subsequent processing.

    syncReqRelaxV2: bool
      ## Allow processing of certain RPC/V2 messages type while syncing (i.e.
      ## `syncReqNewHead` is set.) although `shanghaiTime` is unavailable
      ## or has not reached, yet.

    startOfHistory: Hash256
      ## This setting is needed for resuming blockwise syncying after
      ## installing a snapshot pivot. The default value for this field is
      ## `GENESIS_PARENT_HASH` to start at the very beginning.

    pow: PowRef
      ## Wrapper around `hashimotoLight()` and lookup cache

    poa: Clique
      ## For non-PoA networks this descriptor is ignored.

    pos: CasperRef
      ## Proof Of Stake descriptor

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

proc hardForkTransition*(
  com: CommonRef, forkDeterminer: ForkDeterminationInfo)
  {.gcsafe, raises: [].}

func cliquePeriod*(com: CommonRef): EthTime

func cliqueEpoch*(com: CommonRef): int

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

proc consensusTransition(com: CommonRef, fork: HardFork) =
  if fork >= MergeFork:
    com.consensusType = ConsensusType.POS
  else:
    # restore consensus type to original config
    # this could happen during reorg
    com.consensusType = com.config.consensusType

proc setForkId(com: CommonRef, blockZero: BlockHeader) =
  com.genesisHash = blockZero.blockHash
  let genesisCRC = crc32(0, com.genesisHash.data)
  com.forkIds = calculateForkIds(com.config, genesisCRC)

proc daoCheck(conf: ChainConfig) =
  if not conf.daoForkSupport or conf.daoForkBlock.isNone:
    conf.daoForkBlock = conf.homesteadBlock

  if conf.daoForkSupport and conf.daoForkBlock.isNone:
    conf.daoForkBlock = conf.homesteadBlock

proc init(com      : CommonRef,
          db       : CoreDbRef,
          pruneTrie: bool,
          networkId: NetworkId,
          config   : ChainConfig,
          genesis  : Genesis) {.gcsafe, raises: [CatchableError].} =

  config.daoCheck()

  com.db          = db
  com.pruneTrie   = pruneTrie
  com.config      = config
  com.forkTransitionTable = config.toForkTransitionTable()
  com.networkId   = networkId
  com.syncProgress= SyncProgress()

  # Initalise the PoA state regardless of whether it is needed on the current
  # network. For non-PoA networks this descriptor is ignored.
  com.poa = newClique(com.db, com.cliquePeriod, com.cliqueEpoch)

  # Always initialise the PoW epoch cache even though it migh no be used
  com.pow = PowRef.new
  com.pos = CasperRef.new

  # com.currentFork and com.consensusType
  # is set by hardForkTransition.
  # set it before creating genesis block
  # TD need to be some(0.u256) because it can be the genesis
  # already at the MergeFork
  const TimeZero = EthTime(0)

  # com.forkIds and com.blockZeroHash is set
  # by setForkId
  if genesis.isNil.not:
    com.hardForkTransition(ForkDeterminationInfo(
      blockNumber: 0.toBlockNumber,
      td: some(0.u256),
      time: some(genesis.timestamp)
    ))
    com.genesisHeader = toGenesisHeader(genesis,
      com.currentFork, com.db)
    com.setForkId(com.genesisHeader)
    com.pos.timestamp = genesis.timestamp
  else:
    com.hardForkTransition(ForkDeterminationInfo(
      blockNumber: 0.toBlockNumber,
      td: some(0.u256),
      time: some(TimeZero)
    ))

  # By default, history begins at genesis.
  com.startOfHistory = GENESIS_PARENT_HASH

proc getTd(com: CommonRef, blockHash: Hash256): Option[DifficultyInt] =
  var td: DifficultyInt
  if not com.db.getTd(blockHash, td):
    # TODO: Is this really ok?
    none[DifficultyInt]()
  else:
    some(td)

proc needTdForHardForkDetermination(com: CommonRef): bool =
  let t = com.forkTransitionTable.mergeForkTransitionThreshold
  t.ttdPassed.isNone and t.blockNumber.isNone and t.ttd.isSome

proc getTdIfNecessary(com: CommonRef, blockHash: Hash256): Option[DifficultyInt] =
  if needTdForHardForkDetermination(com):
    getTd(com, blockHash)
  else:
    none[DifficultyInt]()

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc new*(_: type CommonRef,
          db: CoreDbRef,
          pruneTrie: bool = true,
          networkId: NetworkId = MainNet,
          params = networkParams(MainNet)): CommonRef
            {.gcsafe, raises: [CatchableError].} =

  ## If genesis data is present, the forkIds will be initialized
  ## empty data base also initialized with genesis block
  new(result)
  result.init(
    db,
    pruneTrie,
    networkId,
    params.config,
    params.genesis)

proc new*(_: type CommonRef,
          db: CoreDbRef,
          config: ChainConfig,
          pruneTrie: bool = true,
          networkId: NetworkId = MainNet): CommonRef
            {.gcsafe, raises: [CatchableError].} =

  ## There is no genesis data present
  ## Mainly used for testing without genesis
  new(result)
  result.init(
    db,
    pruneTrie,
    networkId,
    config,
    nil)

proc clone*(com: CommonRef, db: CoreDbRef): CommonRef =
  ## clone but replace the db
  ## used in EVM tracer whose db is CaptureDB
  CommonRef(
    db           : db,
    pruneTrie    : com.pruneTrie,
    config       : com.config,
    forkTransitionTable: com.forkTransitionTable,
    forkIds      : com.forkIds,
    genesisHash  : com.genesisHash,
    genesisHeader: com.genesisHeader,
    syncProgress : com.syncProgress,
    networkId    : com.networkId,
    currentFork  : com.currentFork,
    consensusType: com.consensusType,
    pow          : com.pow,
    poa          : com.poa,
    pos          : com.pos
  )

proc clone*(com: CommonRef): CommonRef =
  com.clone(com.db)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func toHardFork*(
    com: CommonRef, forkDeterminer: ForkDeterminationInfo): HardFork =
  toHardFork(com.forkTransitionTable, forkDeterminer)

proc hardForkTransition(
    com: CommonRef, forkDeterminer: ForkDeterminationInfo)
    {.gcsafe, raises: [].} =
  ## When consensus type already transitioned to POS,
  ## the storage can choose not to store TD anymore,
  ## at that time, TD is no longer needed to find a fork
  ## TD only needed during transition from POW/POA to POS.
  ## Same thing happen before London block, TD can be ignored.

  let fork = com.toHardFork(forkDeterminer)
  com.currentFork = fork
  com.consensusTransition(fork)

proc hardForkTransition*(
    com: CommonRef,
    number: BlockNumber,
    td: Option[DifficultyInt],
    time: Option[EthTime])
    {.gcsafe, raises: [].} =
  com.hardForkTransition(ForkDeterminationInfo(
    blockNumber: number, time: time, td: td))

proc hardForkTransition*(
    com: CommonRef,
    parentHash: Hash256,
    number: BlockNumber,
    time: Option[EthTime])
    {.gcsafe, raises: [].} =
  com.hardForkTransition(number, getTdIfNecessary(com, parentHash), time)

proc hardForkTransition*(
    com: CommonRef, header: BlockHeader)
    {.gcsafe, raises: [].} =
  com.hardForkTransition(
    header.parentHash, header.blockNumber, some(header.timestamp))

func toEVMFork*(com: CommonRef, forkDeterminer: ForkDeterminationInfo): EVMFork =
  ## similar to toFork, but produce EVMFork
  let fork = com.toHardFork(forkDeterminer)
  ToEVMFork[fork]

func toEVMFork*(com: CommonRef): EVMFork =
  ToEVMFork[com.currentFork]

func isLondon*(com: CommonRef, number: BlockNumber): bool =
  # TODO: Fixme, use only London comparator
  com.toHardFork(number.blockNumberToForkDeterminationInfo) >= London

func isLondon*(com: CommonRef, number: BlockNumber, timestamp: EthTime): bool =
  # TODO: Fixme, use only London comparator
  com.toHardFork(forkDeterminationInfo(number, timestamp)) >= London

func forkGTE*(com: CommonRef, fork: HardFork): bool =
  com.currentFork >= fork

# TODO: move this consensus code to where it belongs
proc minerAddress*(com: CommonRef; header: BlockHeader): EthAddress
    {.gcsafe, raises: [CatchableError].} =
  if com.consensusType != ConsensusType.POA:
    # POW and POS return header.coinbase
    return header.coinbase

  # POA return ecRecover
  let account = header.ecRecover
  if account.isErr:
    let msg = "Could not recover account address: " & $account.error
    raise newException(ValidationError, msg)

  account.value

func forkId*(com: CommonRef, forkDeterminer: ForkDeterminationInfo): ForkID {.gcsafe.} =
  ## EIP 2364/2124
  let fork = com.toHardFork(forkDeterminer)
  com.forkIds[fork]

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

proc consensus*(com: CommonRef, header: BlockHeader): ConsensusType
                {.gcsafe, raises: [CatchableError].} =
  if com.isBlockAfterTtd(header):
    return ConsensusType.POS

  return com.config.consensusType

proc initializeEmptyDb*(com: CommonRef)
    {.gcsafe, raises: [CatchableError].} =
  let kvt = com.db.kvt()
  if canonicalHeadHashKey().toOpenArray notin kvt:
    trace "Writing genesis to DB"
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

# ------------------------------------------------------------------------------
# Getters
# ------------------------------------------------------------------------------

func startOfHistory*(com: CommonRef): Hash256 =
  ## Getter
  com.startOfHistory

func poa*(com: CommonRef): Clique =
  ## Getter
  com.poa

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

# if you messing with clique period and
# and epoch, it likely will fail clique verification
# at epoch * blocknumber
func cliquePeriod*(com: CommonRef): EthTime =
  if com.config.clique.period.isSome:
    return EthTime com.config.clique.period.get()

func cliqueEpoch*(com: CommonRef): int =
  if com.config.clique.epoch.isSome:
    return com.config.clique.epoch.get()

func pruneTrie*(com: CommonRef): bool =
  com.pruneTrie

# always remember ChainId and NetworkId
# are two distinct things that often got mixed
# because some client do not make distinction
# between them.
# And popular networks such as MainNet
# Goerli, Rinkeby add more confusion to this
# by not make distinction too in their value.
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

func syncReqRelaxV2*(com: CommonRef): bool =
  com.syncReqRelaxV2

# ------------------------------------------------------------------------------
# Setters
# ------------------------------------------------------------------------------

proc `syncStart=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.start = number

proc `syncCurrent=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.current = number

proc `syncHighest=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.highest = number

proc `startOfHistory=`*(com: CommonRef, val: Hash256) =
  ## Setter
  com.startOfHistory = val

proc setTTD*(com: CommonRef, ttd: Option[DifficultyInt]) =
  ## useful for testing
  com.config.terminalTotalDifficulty = ttd
  # rebuild the MergeFork piece of the forkTransitionTable
  com.forkTransitionTable.mergeForkTransitionThreshold = com.config.mergeForkTransitionThreshold

proc setFork*(com: CommonRef, fork: HardFork): Hardfork =
  ## useful for testing
  result = com.currentFork
  com.currentFork = fork
  com.consensusTransition(fork)

proc `syncReqNewHead=`*(com: CommonRef; cb: SyncReqNewHeadCB) =
  ## Activate or reset a call back handler for syncing. When resetting (by
  ## passing `cb` as `nil`), the `syncReqRelaxV2` value is also reset.
  com.syncReqNewHead = cb
  if cb.isNil:
    com.syncReqRelaxV2 = false

proc `syncReqRelaxV2=`*(com: CommonRef; val: bool) =
  ## Allow processing of certain RPC/V2 messages type while syncing (i.e.
  ## `syncReqNewHead` is set.) although `shanghaiTime` is unavailable
  ## or has not reached, yet.
  ##
  ## This setter is effective only while `syncReqNewHead` is activated.
  if not com.syncReqNewHead.isNil:
    com.syncReqRelaxV2 = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
