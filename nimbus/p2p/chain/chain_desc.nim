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
      ## Trigger extra validation, currently with `persistBlocksin()` only.

    cacheByEpoch: EpochHashCache ##\
      ## Objects cache to speed up lookup in validation functions.

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

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newChain*(db: BaseChainDB; poa: Clique; extraValidation = false):
               Chain {.gcsafe, raises: [Defect,CatchableError].} =
  ## Constructor for the `Chain` descriptor object. For most applications,
  ## the `poa` argument is transparent and should be initilaised on the fly
  ## which is available below.
  result.new
  result.db = db

  if not db.config.daoForkSupport:
    db.config.daoForkBlock = db.config.homesteadBlock
  let g = defaultGenesisBlockForNetwork(db.networkId)
  result.blockZeroHash = g.toBlock.blockHash
  let genesisCRC = crc32(0, result.blockZeroHash.data)
  result.forkIds = calculateForkIds(db.config, genesisCRC)
  result.extraValidation = extraValidation

  # Initalise the PoA state regardless of whether it is needed on the current
  # network. For non-PoA networks (when `db.config.poaEngine` is `false`),
  # this descriptor is ignored.
  result.poa = db.newCliqueCfg.newClique

  # Always initialise the epoch cache even though it migh no be used
  # unless `extraValidation` is set `true`.
  result.cacheByEpoch.initEpochHashCache


proc newChain*(db: BaseChainDB, extraValidation = false):
               Chain {.gcsafe, raises: [Defect,CatchableError].} =
  ## Constructor for the `Chain` descriptor object with default initialisation
  ## for the PoA handling. PoA handling is applicable on PoA networks only and
  ## the initialisation (takes place but) is ignored, otherwise.
  db.newChain(db.newCliqueCfg.newClique, extraValidation)

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
