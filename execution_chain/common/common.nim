# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  eth/common/eth_types_json_serialization,
  ../db/[core_db, ledger, storage_types, fcu_db],
  ../utils/[utils],
  ".."/[constants, errors, version_info],
  "."/[chain_config, evmforks, genesis, hardforks],
  taskpools

export
  chain_config,
  core_db,
  constants,
  errors,
  eth_types_json_serialization,
  evmforks,
  genesis,
  hardforks,
  taskpools,
  utils

type
  HeaderChainUpdateCB* = proc(hdr: Header; fin: Hash32) {.gcsafe, raises: [].}
    ## Inform `CL` sub-module `header_chain_cache` about new head.

  BeaconSyncerProgressCB* = proc(): tuple[start, current, target: BlockNumber] {.gcsafe, raises: [].}
    ## Query syncer status

  NotifyBadBlockCB* = proc(invalid, origin: Header) {.gcsafe, raises: [].}
    ## Notify engine-API of encountered bad block

  ResolveFinHashCB* = proc(fin: Hash32) {.gcsafe, raises: [].}

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

    headerChainUpdateCB: HeaderChainUpdateCB
      ## Call back function for a sync processor that returns the canonical
      ## header.

    beaconSyncerProgressCB: BeaconSyncerProgressCB
      ## Call back function querying the status of the sync processor. The
      ## function returns `true` if the syncer is running, downloading or
      ## importing headers and blocks.

    notifyBadBlock: NotifyBadBlockCB
      ## Allow synchronizer to inform engine-API of bad encountered during sync
      ## progress

    resolveFinHash: ResolveFinHashCB

    startOfHistory: Hash32
      ## This setting is needed for resuming blockwise syncying after
      ## installing a snapshot pivot. The default value for this field is
      ## `GENESIS_PARENT_HASH` to start at the very beginning.

    extraData: string
      ## Value of extraData field when building a block

    gasLimit: uint64
      ## Desired gas limit when building a block

    taskpool*: Taskpool
      ## Shared task pool for offloading computation to other threads

    statelessProviderEnabled*: bool
      ## Enable the stateless provider. This turns on the features required
      ## by stateless clients such as generation and storage of block witnesses
      ## and serving these witnesses to peers over the p2p network.

    statelessWitnessValidation*: bool
      ## Enable full validation of execution witnesses.

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

func setForkId(com: CommonRef, genesis: Header) =
  com.genesisHash = genesis.computeBlockHash
  let genesisCRC = crc32(0, com.genesisHash.data)
  com.forkIdCalculator = ForkIdCalculator.init(
    com.forkTransitionTable,
    genesisCRC,
    genesis.timestamp.uint64)

func daoCheck(conf: ChainConfig) =
  if not conf.daoForkSupport or conf.daoForkBlock.isNone:
    conf.daoForkBlock = conf.homesteadBlock

  if conf.daoForkSupport and conf.daoForkBlock.isNone:
    conf.daoForkBlock = conf.homesteadBlock

proc initializeDb(com: CommonRef) =
  let txFrame = com.db.baseTxFrame()
  proc contains(txFrame: CoreDbTxRef; key: openArray[byte]): bool =
    txFrame.hasKeyRc(key).expect "valid bool"
  if canonicalHeadHashKey().toOpenArray notin txFrame:
    let genesisHash = com.genesisHeader.computeBlockHash
    info "Writing genesis to DB",
      blockHash = genesisHash ,
      stateRoot = com.genesisHeader.stateRoot,
      difficulty = com.genesisHeader.difficulty,
      gasLimit = com.genesisHeader.gasLimit,
      timestamp = com.genesisHeader.timestamp,
      nonce = com.genesisHeader.nonce
    doAssert(com.genesisHeader.number == 0.BlockNumber,
      "can't commit genesis block with number > 0")
    txFrame.persistHeaderAndSetHead(com.genesisHeader,
      startOfHistory=com.genesisHeader.parentHash).
      expect("can persist genesis header")
    txFrame.fcuHead(genesisHash, com.genesisHeader.number).
      expect("fcuHead OK")
    doAssert(canonicalHeadHashKey().toOpenArray in txFrame)

    txFrame.checkpoint(com.genesisHeader.number)
    com.db.persist(txFrame)

  # The database must at least contain the base and head pointers - the base
  # is implicitly considered finalized
  let
    baseNum = txFrame.getSavedStateBlockNumber()
    base = txFrame.getBlockHeader(baseNum).valueOr:
      fatal "Cannot load base block header",
        baseNum, err = error
      quit 1
    baseHash = base.computeBlockHash
    finalized = txFrame.fcuFinalized().valueOr:
      debug "Reverting to base", err = error
      FcuHashAndNumber(hash: baseHash, number: base.number)
    head = txFrame.fcuHead().valueOr:
      fatal "Reverting to base", err = error
      FcuHashAndNumber(hash: baseHash, number: base.number)

  info "Database initialized",
    base = (baseHash, base.number),
    finalized = (finalized.hash, finalized.number),
    head = (head.hash, head.number)

proc init(com         : CommonRef,
          db          : CoreDbRef,
          taskpool    : Taskpool,
          networkId   : NetworkId,
          config      : ChainConfig,
          genesis     : Genesis,
          initializeDb: bool,
          statelessProviderEnabled: bool,
          statelessWitnessValidation: bool) =


  config.daoCheck()

  com.db = db
  com.config = config
  com.forkTransitionTable = config.toForkTransitionTable()
  com.networkId = networkId
  com.extraData = ShortClientId
  com.taskpool = taskpool
  com.gasLimit = DEFAULT_GAS_LIMIT

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
      txFrame = db.baseTxFrame()

    # Must not overwrite the global state on the single state DB

    com.genesisHeader = txFrame.getBlockHeader(0.BlockNumber).valueOr:
      toGenesisHeader(genesis, fork, txFrame)

    com.setForkId(com.genesisHeader)

  # By default, history begins at genesis.
  com.startOfHistory = GENESIS_PARENT_HASH

  if initializeDb:
    com.initializeDb()

  com.statelessProviderEnabled = statelessProviderEnabled
  com.statelessWitnessValidation = statelessWitnessValidation

proc isBlockAfterTtd(com: CommonRef, header: Header, txFrame: CoreDbTxRef): bool =
  if com.config.terminalTotalDifficulty.isNone:
    return false

  let
    ttd = com.config.terminalTotalDifficulty.get()
    ptd = txFrame.getScore(header.parentHash).valueOr:
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
    initializeDb = true;
    statelessProviderEnabled = false;
    statelessWitnessValidation = false;
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
    initializeDb,
    statelessProviderEnabled,
    statelessWitnessValidation)

proc new*(
    _: type CommonRef;
    db: CoreDbRef;
    taskpool: Taskpool;
    config: ChainConfig;
    networkId: NetworkId = MainNet;
    initializeDb = true;
    statelessProviderEnabled = false;
    statelessWitnessValidation = false
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
    initializeDb,
    statelessProviderEnabled,
    statelessWitnessValidation)

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
    networkId    : com.networkId,
    statelessProviderEnabled: com.statelessProviderEnabled,
    statelessWitnessValidation: com.statelessWitnessValidation
  )

func clone*(com: CommonRef): CommonRef =
  com.clone(com.db)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func toHardFork*(
    com: CommonRef, forkDeterminer: ForkDeterminationInfo): HardFork =
  toHardFork(com.forkTransitionTable, forkDeterminer)

func toHardFork*(com: CommonRef, timestamp: EthTime): HardFork =
  for fork in countdown(HardFork.high, Shanghai):
    if com.forkTransitionTable.timeThresholds[fork].isSome and timestamp >= com.forkTransitionTable.timeThresholds[fork].get:
      return fork

func toEVMFork*(com: CommonRef, timestamp: EthTime): EVMFork =
  ## similar to toHardFork, but produce EVMFork
  let fork = com.toHardFork(timestamp)
  ToEVMFork[fork]

func toEVMFork*(com: CommonRef, forkDeterminer: ForkDeterminationInfo): EVMFork =
  ## similar to toFork, but produce EVMFork
  let fork = com.toHardFork(forkDeterminer)
  ToEVMFork[fork]

func nextFork*(com: CommonRef, currentFork: HardFork): Opt[HardFork] =
  ## Returns the next hard fork after the given one
  ## The next fork can also be the last fork
  if currentFork < Shanghai:
    return Opt.none(HardFork)
  for fork in currentFork .. HardFork.high:
    if fork > currentFork and com.forkTransitionTable.timeThresholds[fork].isSome:
      return Opt.some(fork)
  return Opt.none(HardFork)

func lastFork*(com: CommonRef, currentFork: HardFork): Opt[HardFork] =
  ## Returns the last hard fork after the current one
  for fork in countdown(HardFork.high, currentFork):
    if fork > currentFork and com.forkTransitionTable.timeThresholds[fork].isSome:
      return Opt.some(HardFork(fork))
  return Opt.none(HardFork)

func activationTime*(com: CommonRef, fork: HardFork): Opt[EthTime] =
  ## Returns the activation time of the given hard fork
  com.forkTransitionTable.timeThresholds[fork]

func toEVMFork*(com: CommonRef, header: Header): EVMFork =
  com.toEVMFork(forkDeterminationInfo(header))

func isSpuriousOrLater*(com: CommonRef, number: BlockNumber): bool =
  com.toHardFork(number.forkDeterminationInfo) >= Spurious

func isByzantiumOrLater*(com: CommonRef, number: BlockNumber): bool =
  com.toHardFork(number.forkDeterminationInfo) >= Byzantium

func isLondonOrLater*(com: CommonRef, number: BlockNumber): bool =
  # TODO: Fixme, use only London comparator
  com.toHardFork(number.forkDeterminationInfo) >= London

func forkId*(com: CommonRef, head, time: uint64): ForkId {.gcsafe.} =
  ## Get ForkId for given block number / timestamp (EIP-2124/2364/6122)
  com.forkIdCalculator.calculateForkId(head, time)

func forkId*(com: CommonRef, forkActivationTime: EthTime): ForkId {.gcsafe.} =
  ## Get ForkId for given timestamp (EIP-2124/2364/6122)
  ## Only works for timestamp based forks
  # For `calculateForkId` with timestamp the block number needs to be set sufficiently
  # high to include all block number based forks.
  # It could be set to `blockNumberThresholds[GrayGlacier]` but then the code needs to
  # deal with possible Opt.none(), so instead set to uint64.high()
  com.forkIdCalculator.calculateForkId(uint64.high(), forkActivationTime.uint64)

func forkId*(com: CommonRef, head: BlockNumber, time: EthTime): ForkId {.gcsafe.} =
  ## Get ForkId for given block number / timestamp (EIP-2124/2364/6122)
  com.forkIdCalculator.calculateForkId(head, time.uint64)

func compatibleForkId*(com: CommonRef, forkId: ForkId, blockNumber: BlockNumber, time: EthTime): bool =
  ## Check if a fork ID is compatible at a specific head position
  com.forkIdCalculator.compatible(forkId, blockNumber, time.uint64)

func isEIP155*(com: CommonRef, number: BlockNumber): bool =
  com.config.eip155Block.isSome and number >= com.config.eip155Block.value

func isShanghaiOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.shanghaiTime.isSome and t >= com.config.shanghaiTime.value

func isCancunOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.cancunTime.isSome and t >= com.config.cancunTime.value

func isPragueOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.pragueTime.isSome and t >= com.config.pragueTime.value

func isOsakaOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.osakaTime.isSome and t >= com.config.osakaTime.value

func isAmsterdamOrLater*(com: CommonRef, t: EthTime): bool =
  com.config.amsterdamTime.isSome and t >= com.config.amsterdamTime.value

func isEip7745OrLater*(com: CommonRef, t: EthTime): bool =
  com.config.eip7745Time.isSome and t >= com.config.eip7745Time.value

proc proofOfStake*(com: CommonRef, header: Header, txFrame: CoreDbTxRef): bool =
  if com.config.posBlock.isSome:
    # see comments of posBlock in common/hardforks.nim
    header.number >= com.config.posBlock.get
  elif com.config.mergeNetsplitBlock.isSome:
    header.number >= com.config.mergeNetsplitBlock.get
  else:
    # This costly check is only executed from test suite
    com.isBlockAfterTtd(header, txFrame)

func depositContractAddress*(com: CommonRef): Address =
  com.config.depositContractAddress.get(default(Address))

proc headerChainUpdate*(com: CommonRef; header: Header; finHash: Hash32) =
  ## Used by RPC updater
  if not com.headerChainUpdateCB.isNil:
    com.headerChainUpdateCB(header, finHash)

proc beaconSyncerProgress*(com: CommonRef): tuple[start, current, target: BlockNumber] =
  ## Query syncer status
  if not com.beaconSyncerProgressCB.isNil:
    return com.beaconSyncerProgressCB()
  # (0,0,0)

proc notifyBadBlock*(com: CommonRef; invalid, origin: Header)
    {.gcsafe, raises: [].} =

  if not com.notifyBadBlock.isNil:
    com.notifyBadBlock(invalid, origin)

proc resolveFinHash*(com: CommonRef; fin: Hash32) =
  if not com.resolveFinHash.isNil:
    com.resolveFinHash(fin)

# ------------------------------------------------------------------------------
# Getters
# ------------------------------------------------------------------------------

func startOfHistory*(com: CommonRef): Hash32 =
  ## Getter
  com.startOfHistory

func db*(com: CommonRef): CoreDbRef =
  com.db

func eip150Block*(com: CommonRef): Opt[BlockNumber] =
  com.config.eip150Block

func eip150Hash*(com: CommonRef): Hash32 =
  com.config.eip150Hash

func daoForkBlock*(com: CommonRef): Opt[BlockNumber] =
  com.config.daoForkBlock

func posBlock*(com: CommonRef): Opt[BlockNumber] =
  com.config.posBlock

func daoForkSupport*(com: CommonRef): bool =
  com.config.daoForkSupport

func ttd*(com: CommonRef): Opt[DifficultyInt] =
  com.config.terminalTotalDifficulty

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

func extraData*(com: CommonRef): string =
  com.extraData

func gasLimit*(com: CommonRef): uint64 =
  com.gasLimit

func maxBlobsPerBlock*(com: CommonRef, fork: HardFork): uint64 =
  doAssert(fork >= Cancun)
  com.config.blobSchedule[fork].expect("blobSchedule initialized").max

func targetBlobsPerBlock*(com: CommonRef, fork: HardFork): uint64 =
  doAssert(fork >= Cancun)
  com.config.blobSchedule[fork].expect("blobSchedule initialized").target

func baseFeeUpdateFraction*(com: CommonRef, fork: HardFork): uint64 =
  doAssert(fork >= Cancun)
  com.config.blobSchedule[fork].expect("blobSchedule initialized").baseFeeUpdateFraction

# ------------------------------------------------------------------------------
# Setters

func `startOfHistory=`*(com: CommonRef, val: Hash32) =
  ## Setter
  com.startOfHistory = val

func setTTD*(com: CommonRef, ttd: Opt[DifficultyInt]) =
  ## useful for testing
  com.config.terminalTotalDifficulty = ttd
  # rebuild the MergeFork piece of the forkTransitionTable
  com.forkTransitionTable.mergeForkTransitionThreshold = com.config.mergeForkTransitionThreshold

func `headerChainUpdate=`*(com: CommonRef; cb: HeaderChainUpdateCB) =
  ## Activate or reset a call back handler for syncing.
  com.headerChainUpdateCB = cb

func `beaconSyncerProgress=`*(com: CommonRef; cb: BeaconSyncerProgressCB) =
  ## Activate or reset a call back handler for querying syncer.
  com.beaconSyncerProgressCB = cb

func `notifyBadBlock=`*(com: CommonRef; cb: NotifyBadBlockCB) =
  ## Activate or reset a call back handler for bad block notification.
  com.notifyBadBlock = cb

func `resolveFinHash=`*(com: CommonRef; cb: ResolveFinHashCB) =
  com.resolveFinHash = cb

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
