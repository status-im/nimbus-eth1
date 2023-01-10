# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options],
  chronicles,
  eth/trie/trie_defs,
  ./chain_config,
  ./hardforks,
  ./evmforks,
  ./genesis,
  ./eips,
  ../utils/[utils, ec_recover],
  ../db/[db_chain, storage_types],
  ../core/[pow, clique, casper]

export
  chain_config,
  db_chain,
  options,
  evmforks,
  hardforks,
  genesis,
  utils,
  eips.EIP

type
  SyncProgress = object
    start  : BlockNumber
    current: BlockNumber
    highest: BlockNumber

  CommonRef* = ref object
    # all purpose storage
    db: ChainDBRef

    # prune underlying state db?
    pruneTrie: bool

    # block chain config
    config: ChainConfig

    # cache of genesis
    genesisHash: KeccakHash
    genesisHeader: BlockHeader

    # map block number and ttd to
    # HardFork
    forkToBlock: ForkToBlockNumber
    blockToFork: BlockToForks

    # Eth wire protocol need this
    forkIds: array[HardFork, ForkID]
    networkId: NetworkId

    # synchronizer need this
    syncProgress: SyncProgress

    # current hard fork, updated after calling `hardForkTransition`
    currentFork: HardFork

    # one of POW/POA/POS, updated after calling `hardForkTransition`
    consensusType: ConsensusType

    pow: PowRef ##\
      ## Wrapper around `hashimotoLight()` and lookup cache

    poa: Clique ##\
      ## For non-PoA networks this descriptor is ignored.

    pos: CasperRef
      ## Proof Of Stake descriptor

    eips: ForkToEIP

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

proc hardForkTransition*(com: CommonRef,
  number: BlockNumber, td: Option[DifficultyInt]) {.gcsafe.}

func cliquePeriod*(com: CommonRef): int

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

proc setForkId(com: CommonRef, blockZero: BlockHeader)
  {. raises: [Defect,CatchableError].} =
  com.genesisHash = blockZero.blockHash
  let genesisCRC = crc32(0, com.genesisHash.data)
  com.forkIds = calculateForkIds(com.config, genesisCRC)

proc daoCheck(conf: ChainConfig) =
  if not conf.daoForkSupport or conf.daoForkBlock.isNone:
    conf.daoForkBlock = conf.homesteadBlock

  if conf.daoForkSupport and conf.daoForkBlock.isNone:
    conf.daoForkBlock = conf.homesteadBlock

proc init(com      : CommonRef,
          db       : TrieDatabaseRef,
          pruneTrie: bool,
          networkId: NetworkId,
          config   : ChainConfig,
          genesis  : Genesis) =

  config.daoCheck()

  com.db          = ChainDBRef.new(db)
  com.pruneTrie   = pruneTrie
  com.config      = config
  com.forkToBlock = config.toForkToBlockNumber()
  com.blockToFork = config.blockToForks(com.forkToBlock)
  com.networkId   = networkId
  com.syncProgress= SyncProgress()

  # com.currentFork and com.consensusType
  # is set by hardForkTransition.
  # set it before creating genesis block
  # TD need to be some(0.u256) because it can be the genesis
  # already at the MergeFork
  com.hardForkTransition(0.toBlockNumber, some(0.u256))

  # com.forkIds and com.blockZeroHash is set
  # by setForkId
  if genesis.isNil.not:
    com.genesisHeader = toGenesisHeader(genesis,
      com.currentFork, com.db.db)
    com.setForkId(com.genesisHeader)

  # Initalise the PoA state regardless of whether it is needed on the current
  # network. For non-PoA networks this descriptor is ignored.
  com.poa = newClique(com.db, com.cliquePeriod, com.cliqueEpoch)

  # Always initialise the PoW epoch cache even though it migh no be used
  com.pow = PowRef.new
  com.pos = CasperRef.new

  # allow runtime configuration of EIPs
  com.eips = ForkToEipList

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc new*(_: type CommonRef,
          db: TrieDatabaseRef,
          pruneTrie: bool = true,
          networkId: NetworkId = MainNet,
          params = networkParams(MainNet)): CommonRef =

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
          db: TrieDatabaseRef,
          config: ChainConfig,
          pruneTrie: bool = true,
          networkId: NetworkId = MainNet): CommonRef =

  ## There is no genesis data present
  ## Mainly used for testing without genesis
  new(result)
  result.init(
    db,
    pruneTrie,
    networkId,
    config,
    nil)

proc clone*(com: CommonRef, db: TrieDatabaseRef): CommonRef =
  ## clone but replace the db
  ## used in EVM tracer whose db is CaptureDB
  CommonRef(
    db           : ChainDBRef.new(db),
    pruneTrie    : com.pruneTrie,
    config       : com.config,
    forkToBlock  : com.forkToBlock,
    blockToFork  : com.blockToFork,
    forkIds      : com.forkIds,
    genesisHash  : com.genesisHash,
    genesisHeader: com.genesisHeader,
    syncProgress : com.syncProgress,
    networkId    : com.networkId,
    currentFork  : com.currentFork,
    consensusType: com.consensusType,
    pow          : com.pow,
    poa          : com.poa,
    pos          : com.pos,
    eips         : com.eips
  )

proc clone*(com: CommonRef): CommonRef =
  com.clone(com.db.db)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func toHardFork*(com: CommonRef, number: BlockNumber): HardFork =
  ## doesn't do transition
  ## only want to know a particular block number
  ## belongs to which fork without considering TD or TTD
  ## MergeFork: assume the MergeForkBlock isSome,
  ## if there is a MergeFork, thus bypassing the TD >= TTD
  ## comparison
  toHardFork(com.forkToBlock, number)

proc hardForkTransition(com: CommonRef,
     number: BlockNumber, td: Option[DifficultyInt])
      {.gcsafe, raises: [Defect, CatchableError].} =
  ## When consensus type already transitioned to POS,
  ## the storage can choose not to store TD anymore,
  ## at that time, TD is no longer needed to find a fork
  ## TD only needed during transition from POW/POA to POS.
  ## Same thing happen before London block, TD can be ignored.

  if td.isNone:
    # fork transition ignoring TD
    let fork = com.toHardFork(number)
    com.currentFork = fork
    com.consensusTransition(fork)
    return

  # fork transition considering TD
  let td = td.get()
  for fork in countdown(HardFork.high, HardFork.low):
    let x = com.blockToFork[fork]
    if x.toFork(x.data, number, td):
      com.currentFork = fork
      com.consensusTransition(fork)
      return

  # should always have a match
  doAssert(false, "unreachable code")

proc hardForkTransition*(com: CommonRef, parentHash: Hash256,
                         number: BlockNumber)
                         {.gcsafe, raises: [Defect, CatchableError].} =

  # if mergeForkBlock is present, it has higher
  # priority than TTD
  if com.config.mergeForkBlock.isSome or
     com.config.terminalTotalDifficulty.isNone:
    let fork = com.toHardFork(number)
    com.currentFork = fork
    com.consensusTransition(fork)
    return

  var td: DifficultyInt
  if not com.db.getTd(parentHash, td):
    # TODO: Is this really ok?
    let fork = com.toHardFork(number)
    com.currentFork = fork
    com.consensusTransition(fork)
    return

  for fork in countdown(HardFork.high, HardFork.low):
    let x = com.blockToFork[fork]
    if x.toFork(x.data, number, td):
      com.currentFork = fork
      com.consensusTransition(fork)
      return

  # should always have a match
  doAssert(false, "unreachable code")

proc hardForkTransition*(com: CommonRef, header: BlockHeader)
                        {.gcsafe, raises: [Defect, CatchableError].} =

  com.hardForkTransition(header.parentHash, header.blockNumber)

func toEVMFork*(com: CommonRef, number: BlockNumber): EVMFork =
  ## similar to toFork, but produce EVMFork
  ## be aware that if MergeFork is not set in
  ## chain config, this function probably give wrong
  ## result because no TD is put into consideration
  let fork = com.toHardFork(number)
  ToEVMFork[fork]

func isLondon*(com: CommonRef, number: BlockNumber): bool =
  # TODO: Fixme, use only London comparator
  com.toHardFork(number) >= London

func forkGTE*(com: CommonRef, fork: HardFork): bool =
  com.currentFork >= fork

# TODO: move this consensus code to where it belongs
proc minerAddress*(com: CommonRef; header: BlockHeader): EthAddress
    {.gcsafe, raises: [Defect,CatchableError].} =
  if com.consensusType != ConsensusType.POA:
    # POW and POS return header.coinbase
    return header.coinbase

  # POA return ecRecover
  let account = header.ecRecover
  if account.isErr:
    let msg = "Could not recover account address: " & $account.error
    raise newException(ValidationError, msg)

  account.value

func forkId*(com: CommonRef, number: BlockNumber): ForkID {.gcsafe.} =
  ## EIP 2364/2124
  let fork = com.toHardFork(number)
  com.forkIds[fork]

func isEIP155*(com: CommonRef, number: BlockNumber): bool =
  com.config.eip155Block.isSome and number >= com.config.eip155Block.get

proc isBlockAfterTtd*(com: CommonRef, header: BlockHeader): bool
                      {.gcsafe, raises: [Defect,CatchableError].} =
  if com.config.terminalTotalDifficulty.isNone:
    return false

  let
    ttd = com.config.terminalTotalDifficulty.get()
    ptd = com.db.getScore(header.parentHash)
    td  = ptd + header.difficulty
  ptd >= ttd and td >= ttd

proc consensus*(com: CommonRef, header: BlockHeader): ConsensusType
                {.gcsafe, raises: [Defect,CatchableError].} =
  if com.isBlockAfterTtd(header):
    return ConsensusType.POS

  return com.config.consensusType

proc initializeEmptyDb*(com: CommonRef)
    {.raises: [Defect, CatchableError].} =
  let trieDB = com.db.db
  if canonicalHeadHashKey().toOpenArray notin trieDB:
    trace "Writing genesis to DB"
    doAssert(com.genesisHeader.blockNumber.isZero,
      "can't commit genesis block with number > 0")
    discard com.db.persistHeaderToDb(com.genesisHeader,
      com.consensusType == ConsensusType.POS)
    doAssert(canonicalHeadHashKey().toOpenArray in trieDB)

# ------------------------------------------------------------------------------
# Getters
# ------------------------------------------------------------------------------
proc poa*(com: CommonRef): Clique =
  ## Getter
  com.poa

proc pow*(com: CommonRef): PowRef =
  ## Getter
  com.pow

proc pos*(com: CommonRef): CasperRef =
  ## Getter
  com.pos

func db*(com: CommonRef): ChainDBRef =
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

# if you messing with clique period and
# and epoch, it likely will fail clique verification
# at epoch * blocknumber
func cliquePeriod*(com: CommonRef): int =
  if com.config.clique.period.isSome:
    return com.config.clique.period.get()

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

# ------------------------------------------------------------------------------
# Setters
# ------------------------------------------------------------------------------

proc `syncStart=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.start = number

proc `syncCurrent=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.current = number

proc `syncHighest=`*(com: CommonRef, number: BlockNumber) =
  com.syncProgress.highest = number

proc setTTD*(com: CommonRef, ttd: Option[DifficultyInt]) =
  ## useful for testing
  com.config.terminalTotalDifficulty = ttd
  # rebuild blockToFork
  # TODO: Fix me, only need to rebuild MergeFork comparator
  com.blockToFork = com.config.blockToForks(com.forkToBlock)

proc setFork*(com: CommonRef, fork: HardFork): Hardfork =
  ## useful for testing
  result = com.currentFork
  com.currentFork = fork
  com.consensusTransition(fork)

# ------------------------------------------------------------------------------
# EIPs procs
# ------------------------------------------------------------------------------

proc activate*(com: CommonRef, fork: HardFork, eip: EIP) =
  com.eips[fork].incl eip

proc deactivate*(com: CommonRef, fork: HardFork, eip: EIP) =
  com.eips[fork].excl eip

func activated*(com: CommonRef, eip: EIP): bool =
  eip in com.eips[com.currentFork]
