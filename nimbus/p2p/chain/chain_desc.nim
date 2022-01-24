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
  ../../utils/pow,
  ../../chain_config,
  ../clique,
  ../validate,
  chronicles,
  eth/[common, trie/db],
  stew/endians2,
  stint

type
  ChainFork* = enum
    ## `ChainFork` has extra forks not in the EVM fork list.  These are the
    ## unique `DAOFork`, and Glacier forks `MuirGlacier` and `ArrowGlacier`.
    ## At the Glacier forks, only block difficulty calculation changed.
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
    London,
    ArrowGlacier

  Chain* = ref object of AbstractChainDB
    db: BaseChainDB
    forkIds: array[ChainFork, ForkID]

    blockZeroHash: KeccakHash ##\
      ## Overload cache for `genesisHash()` method

    extraValidation: bool ##\
      ## Trigger extra validation, currently within `persistBlocks()`
      ## function only.

    verifyFrom: BlockNumber ##\
      ## First block to when `extraValidation` will be applied (only
      ## effective if `extraValidation` is true.)

    pow: PowRef ##\
      ## Wrapper around `hashimotoLight()` and lookup cache

    poa: Clique ##\
      ## For non-PoA networks (when `db.config.poaEngine` is `false`),
      ## this descriptor is ignored.

    ttdReachedAt*: Option[BlockNumber]
      ## The first block which difficulty was above the terminal
      ## total difficulty. In networks with TTD=0, this would be
      ## the very first block.

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

func toNextFork(n: BlockNumber): uint64 =
  if n == high(BlockNumber):
    result = 0'u64
  else:
    result = n.truncate(uint64)

func isBlockAfterTtd*(c: Chain, blockHeader: BlockHeader): bool =
  # TODO: This should be fork aware
  c.ttdReachedAt.isSome and blockHeader.blockNumber > c.ttdReachedAt.get

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
    toNextFork(c.londonBlock),
    toNextFork(c.arrowGlacierBlock)
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

proc setForkId(c: Chain)
  {. raises: [Defect,CatchableError].} =
  c.blockZeroHash = toBlock(c.db.genesis).blockHash
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
  c.setForkId()

  # Initalise the PoA state regardless of whether it is needed on the current
  # network. For non-PoA networks (when `db.config.poaEngine` is `false`),
  # this descriptor is ignored.
  c.poa = db.newClique

  # Always initialise the PoW epoch cache even though it migh no be used
  # unless `extraValidation` is set `true`.
  c.pow = PowRef.new

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

proc clique*(c: Chain): var Clique =
  ## Getter
  c.poa

proc pow*(c: Chain): PowRef =
  ## Getter
  c.pow

proc db*(c: Chain): BaseChainDB =
  ## Getter
  c.db

proc extraValidation*(c: Chain): bool =
  ## Getter
  c.extraValidation

proc forkIds*(c: Chain): array[ChainFork,ForkID] =
  ## Getter
  c.forkIds

proc verifyFrom*(c: Chain): BlockNumber =
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

proc `extraValidation=`*(c: Chain; extraValidation: bool) =
  ## Setter. If set `true`, the assignment value `extraValidation` enables
  ## extra block chain validation.
  c.extraValidation = extraValidation

proc `verifyFrom=`*(c: Chain; verifyFrom: BlockNumber) =
  ## Setter. The  assignment value `verifyFrom` defines the first block where
  ## validation should start if the `Clique` field `extraValidation` was set
  ## `true`.
  c.verifyFrom = verifyFrom

proc `verifyFrom=`*(c: Chain; verifyFrom: uint64) =
  ## Variant of `verifyFrom=`
  c.verifyFrom = verifyFrom.u256

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
