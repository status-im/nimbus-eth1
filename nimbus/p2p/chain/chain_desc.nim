# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../chain_config,
  ../../db/db_chain,
  ../../genesis,
  ../../utils,
  ../../chain_config,
  ../clique,
  ../validate,
  ../validate/epoch_hash_cache,
  chronicles,
  eth/[common, trie/db],
  stew/endians2,
  stint

type
  # Chain's forks not always equals to EVM's forks
  ChainFork* = enum
    Frontier,
    Homestead,
    DAOFork,
    Tangerine,
    Spurious,
    Byzantium,
    Constantinople,
    Petersburg,
    Istanbul,
    MuirGlacier,
    Berlin,
    London

  Chain* = ref object of AbstractChainDB
    db: BaseChainDB
    forkIds: array[ChainFork, ForkID]
    blockZeroHash: KeccakHash

    extraValidation: bool ##\
      ## Trigger extra validation, currently within `persistBlocks()`
      ## function only.

    verifyFrom: BlockNumber ##\
      ## First block to when `extraValidation` will be applied (only
      ## effective if `extraValidation` is true.)

    cacheByEpoch: EpochHashCache ##\
      ## Objects cache to speed up hash lookup in validation functions.

    poa: Clique ##\
      ## For non-PoA networks (when `db.config.poaEngine` is `false`),
      ## this descriptor is ignored.

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

func toNextFork(n: BlockNumber): uint64 =
  if n == high(BlockNumber):
    result = 0'u64
  else:
    result = n.truncate(uint64)

func getNextFork(c: ChainConfig, fork: ChainFork): uint64 =
  let next: array[ChainFork, uint64] = [
    0'u64,
    toNextFork(c.homesteadBlock),
    toNextFork(c.daoForkBlock),
    toNextFork(c.eip150Block),
    toNextFork(c.eip158Block),
    toNextFork(c.byzantiumBlock),
    toNextFork(c.constantinopleBlock),
    toNextFork(c.petersburgBlock),
    toNextFork(c.istanbulBlock),
    toNextFork(c.muirGlacierBlock),
    toNextFork(c.berlinBlock),
    toNextFork(c.londonBlock)
  ]

  if fork == high(ChainFork):
    result = 0
    return

  result = next[fork]
  for x in fork..high(ChainFork):
    if result != next[x]:
      result = next[x]
      break

func calculateForkId(c: ChainConfig, fork: ChainFork,
                     prevCRC: uint32, prevFork: uint64): ForkID =
  result.nextFork = c.getNextFork(fork)

  if result.nextFork != prevFork:
    result.crc = crc32(prevCRC, toBytesBE(prevFork))
  else:
    result.crc = prevCRC

func calculateForkIds(c: ChainConfig,
                      genesisCRC: uint32): array[ChainFork, ForkID] =
  var prevCRC = genesisCRC
  var prevFork = c.getNextFork(Frontier)

  for fork in ChainFork:
    result[fork] = calculateForkId(c, fork, prevCRC, prevFork)
    prevFork = result[fork].nextFork
    prevCRC = result[fork].crc

proc setForkId(c: Chain, cn: CustomNetwork)
  {. raises: [Defect,CatchableError].} =
  let g = genesisBlockForNetwork(c.db.networkId, cn)
  c.blockZeroHash = g.toBlock.blockHash
  let genesisCRC = crc32(0, c.blockZeroHash.data)
  c.forkIds = calculateForkIds(c.db.config, genesisCRC)

# ------------------------------------------------------------------------------
# Private constructor helper
# ------------------------------------------------------------------------------

proc initChain(c: Chain; db: BaseChainDB; poa: Clique; extraValidation: bool)
                  {.gcsafe, raises: [Defect,CatchableError].} =
  ## Constructor for the `Chain` descriptor object. For most applications,
  ## the `poa` argument is transparent and should be initilaised on the fly
  ## which is available below.
  c.db = db

  if not db.config.daoForkSupport:
    db.config.daoForkBlock = db.config.homesteadBlock
  c.extraValidation = extraValidation
  c.setForkId(db.customNetwork)

  # Initalise the PoA state regardless of whether it is needed on the current
  # network. For non-PoA networks (when `db.config.poaEngine` is `false`),
  # this descriptor is ignored.
  c.poa = db.newClique

  # Always initialise the epoch cache even though it migh no be used
  # unless `extraValidation` is set `true`.
  c.cacheByEpoch.initEpochHashCache

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc newChain*(db: BaseChainDB; poa: Clique; extraValidation: bool): Chain
                 {.gcsafe, raises: [Defect,CatchableError].} =
  ## Constructor for the `Chain` descriptor object. For most applications,
  ## the `poa` argument is transparent and should be initilaised on the fly
  ## which is available below. The argument `extraValidation` enables extra
  ## block chain validation if set `true`.
  new result
  result.initChain(db, poa, extraValidation)


proc newChain*(db: BaseChainDB, extraValidation: bool): Chain
                 {.gcsafe, raises: [Defect,CatchableError].} =
  ## Constructor for the `Chain` descriptor object with default initialisation
  ## for the PoA handling. The argument `extraValidation` enables extra block
  ## chain validation if set `true`.
  new result
  result.initChain(db, db.newClique, extraValidation)

proc newChain*(db: BaseChainDB): Chain
                 {.gcsafe, raises: [Defect,CatchableError].} =
  ## Constructor for the `Chain` descriptor object. All sub-object descriptors
  ## are initialised with defaults. So is extra block chain validation
  ##  * `enabled` for PoA networks (such as Goerli)
  ##  * `disabled` for nopn-PaA networks
  new result
  result.initChain(db, db.newClique, db.config.poaEngine)

# ------------------------------------------------------------------------------
# Public `AbstractChainDB` getter overload  methods
# ------------------------------------------------------------------------------

method genesisHash*(c: Chain): KeccakHash {.gcsafe.} =
  ## Getter: `AbstractChainDB` overload method
  c.blockZeroHash

method getBestBlockHeader*(c: Chain): BlockHeader
                           {.gcsafe, raises: [Defect,CatchableError].} =
  ## Getter: `AbstractChainDB` overload method
  c.db.getCanonicalHead()

method getTrieDB*(c: Chain): TrieDatabaseRef {.gcsafe.} =
  ## Getter: `AbstractChainDB` overload method
  c.db.db

# ------------------------------------------------------------------------------
# Public `Chain` getters
# ------------------------------------------------------------------------------

proc clique*(c: Chain): var Clique {.inline.} =
  ## Getter
  c.poa

proc cacheByEpoch*(c: Chain): var EpochHashCache {.inline.} =
  ## Getter
  c.cacheByEpoch

proc db*(c: Chain): auto {.inline.} =
  ## Getter
  c.db

proc extraValidation*(c: Chain): auto {.inline.} =
  ## Getter
  c.extraValidation

proc forkIds*(c: Chain): auto {.inline.} =
  ## Getter
  c.forkIds

proc verifyFrom*(c: Chain): auto {.inline.} =
  ## Getter
  c.verifyFrom

proc currentBlock*(c: Chain): BlockHeader
  {.gcsafe, raises: [Defect,CatchableError].} =
  ## currentBlock retrieves the current head block of the canonical chain.
  ## Ideally the block should be retrieved from the blockchain's internal cache.
  ## but now it's enough to retrieve it from database
  c.db.getCanonicalHead()

# ------------------------------------------------------------------------------
# Public `Chain` setters
# ------------------------------------------------------------------------------

proc `extraValidation=`*(c: Chain; extraValidation: bool) {.inline.} =
  ## Setter. If set `true`, the assignment value `extraValidation` enables
  ## extra block chain validation.
  c.extraValidation = extraValidation

proc `verifyFrom=`*(c: Chain; verifyFrom: uint64) {.inline.} =
  ## Setter. The  assignment value `verifyFrom` defines the first block where
  ## validation should start if the `Clique` field `extraValidation` was set
  ## `true`.
  c.verifyFrom = verifyFrom.u256

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
