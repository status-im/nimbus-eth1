# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options, strutils],
  eth/common,
  results,
  stew/endians2,
  json_serialization,
  ../utils/utils,
  ./evmforks

{.push raises: [].}

type
  ConsensusType* {.pure.} = enum
    # Proof of Work
    # algorithm: Ethash
    POW

    # Proof of Stake
    # algorithm: Casper
    POS

  HardFork* = enum
    Frontier
    Homestead
    DAOFork
    Tangerine       # a.k.a. EIP150
    Spurious        # a.k.a. EIP158
    Byzantium
    Constantinople
    Petersburg      # a.k.a. ConstantinopleFix
    Istanbul
    MuirGlacier
    Berlin
    London
    ArrowGlacier
    GrayGlacier
    MergeFork       # a.k.a. Paris
    Shanghai
    Cancun
    Prague

const lastPurelyBlockNumberBasedFork* = GrayGlacier
# MergeFork is special because of TTD.
const firstTimeBasedFork* = Shanghai


type
  MergeForkTransitionThreshold* = object
    blockNumber*: Option[BlockNumber]
    ttd*: Option[DifficultyInt]
    ttdPassed*: Option[bool]

  ForkTransitionTable* = object
    blockNumberThresholds*: array[Frontier..GrayGlacier, Option[BlockNumber]]
    mergeForkTransitionThreshold*: MergeForkTransitionThreshold
    timeThresholds*: array[Shanghai..Prague, Option[EthTime]]

  # Starting with Shanghai, forking is based on timestamp
  # rather than block number.
  #
  # I'm not sure what to call this type, but we used to pass
  # just the block number into various places that need to
  # determine which fork we're on, and now we need to pass
  # around both block number and also time. And the config
  # info for each individual fork will be either a block
  # number or a time.
  #
  # Note that time and TD are optional. TD being optional
  # is because it's perfectly fine, if mergeForkBlock is
  # set, to not bother with TTD anymore. But I'm not sure
  # it makes sense to allow time to be optional. See the
  # comment below on forkDeterminationInfo.
  ForkDeterminationInfo* = object
    blockNumber*: BlockNumber
    time*: Opt[EthTime]
    td*: Opt[DifficultyInt]

func forkDeterminationInfo*(n: BlockNumber): ForkDeterminationInfo =
  # FIXME: All callers of this function are suspect; I'm guess we should
  # always be using both block number and time. But we have a few places,
  # like various tests, where we only have block number and the tests are
  # meant for pre-Merge forks, so maybe those are okay.
  ForkDeterminationInfo(
    blockNumber: n, time: Opt.none(EthTime), td: Opt.none(DifficultyInt))

func forkDeterminationInfo*(n: BlockNumber, t: EthTime): ForkDeterminationInfo =
  ForkDeterminationInfo(
    blockNumber: n, time: Opt.some(t), td: Opt.none(DifficultyInt))

func forkDeterminationInfo*(header: BlockHeader): ForkDeterminationInfo =
  # FIXME-Adam-mightAlsoNeedTTD?
  forkDeterminationInfo(header.blockNumber, header.timestamp)

func adjustForNextBlock*(n: BlockNumber): BlockNumber =
  n + 1

func adjustForNextBlock*(t: EthTime): EthTime =
  # FIXME-Adam: what's the right thing to do here?
  # How do we calculate "the timestamp for the block
  # after this one"?
  #
  # If this makes no sense, what should the callers
  # do instead?
  t + 12

func adjustForNextBlock*(f: ForkDeterminationInfo): ForkDeterminationInfo =
  ForkDeterminationInfo(
    blockNumber: adjustForNextBlock(f.blockNumber),
    time: f.time.map(adjustForNextBlock),
    td: f.td
  )

# This function is awkward because there are various different ways now of
# doing a hard-fork transition (block number, ttd, time, block number *or*
# time). We used to have a simple array called forkToBlock that mapped each
# HardFork to a BlockNumber; now we have this ForkTransitionTable, which
# contains a couple of arrays and also special cases for MergeBlock and
# Shanghai.
func isGTETransitionThreshold*(map: ForkTransitionTable, forkDeterminer: ForkDeterminationInfo, fork: HardFork): bool =
  if fork <= lastPurelyBlockNumberBasedFork:
    map.blockNumberThresholds[fork].isSome and forkDeterminer.blockNumber >= map.blockNumberThresholds[fork].get
  elif fork == MergeFork:
    # MergeFork is a special case that can use either block number or ttd;
    # ttdPassed > block number > ttd takes precedence.
    let t = map.mergeForkTransitionThreshold
    if t.ttdPassed.isSome:
      t.ttdPassed.get
    elif t.blockNumber.isSome:
      forkDeterminer.blockNumber >= t.blockNumber.get
    elif t.ttd.isSome and forkDeterminer.td.isSome:
      forkDeterminer.td.get >= t.ttd.get
    else:
      false
  elif fork <= HardFork.high:
    map.timeThresholds[fork].isSome and forkDeterminer.time.isSome and forkDeterminer.time.get >= map.timeThresholds[fork].get
  else:
    raise newException(Defect, "Why is this hard fork not in one of the above categories?")

type
  # if you add more fork block
  # please update forkBlockField constant too
  ChainConfig* = ref object
    chainId*            : ChainId
    homesteadBlock*     : Option[BlockNumber]
    daoForkBlock*       : Option[BlockNumber]
    daoForkSupport*     : bool
    eip150Block*        : Option[BlockNumber]
    eip150Hash*         : Hash256
    eip155Block*        : Option[BlockNumber]
    eip158Block*        : Option[BlockNumber]
    byzantiumBlock*     : Option[BlockNumber]
    constantinopleBlock*: Option[BlockNumber]
    petersburgBlock*    : Option[BlockNumber]
    istanbulBlock*      : Option[BlockNumber]
    muirGlacierBlock*   : Option[BlockNumber]
    berlinBlock*        : Option[BlockNumber]
    londonBlock*        : Option[BlockNumber]
    arrowGlacierBlock*  : Option[BlockNumber]
    grayGlacierBlock*   : Option[BlockNumber]

    # mergeNetsplitBlock is an alias to mergeForkBlock
    # and is used for geth compatibility layer
    mergeNetsplitBlock* : Option[BlockNumber]

    mergeForkBlock*     : Option[BlockNumber]
    shanghaiTime*       : Option[EthTime]
    cancunTime*         : Option[EthTime]
    pragueTime*         : Option[EthTime]

    terminalTotalDifficulty*: Option[UInt256]
    terminalTotalDifficultyPassed*: Option[bool]
    consensusType*
      {.dontSerialize.} : ConsensusType

  # These are used for checking that the values of the fields
  # are in a valid order.
  BlockNumberBasedForkOptional* = object
    name*: string
    number*: Option[BlockNumber]
  TimeBasedForkOptional* = object
    name*: string
    time*: Option[EthTime]

func countTimeFields(): int {.compileTime.} =
  var z = ChainConfig()
  for name, _ in fieldPairs(z[]):
    if name.endsWith("Time"):
      inc result

func countBlockFields(): int {.compileTime.} =
  var z = ChainConfig()
  for name, _ in fieldPairs(z[]):
    if name == "mergeNetsplitBlock":
      # skip mergeForkBlock alias
      # continue is not supported
      discard
    elif name.endsWith("Block"):
      inc result

const
  timeFieldsCount = countTimeFields()
  blockFieldsCount = countBlockFields()

func collectTimeFields(): array[timeFieldsCount, string] =
  var z = ChainConfig()
  var i = 0
  for name, _ in fieldPairs(z[]):
    if name.endsWith("Time"):
      result[i] = name
      inc i

func collectBlockFields(): array[blockFieldsCount, string] =
  var z = ChainConfig()
  var i = 0
  for name, _ in fieldPairs(z[]):
    if name == "mergeNetsplitBlock":
      # skip mergeForkBlock alias
      # continue is not supported
      discard
    elif name.endsWith("Block"):
      result[i] = name
      inc i

const
  # this table is used for generate
  # code at compile time to check
  # the order of blok number in ChainConfig
  forkBlockField* = collectBlockFields()
  forkTimeField* = collectTimeFields()


func mergeForkTransitionThreshold*(conf: ChainConfig): MergeForkTransitionThreshold =
  MergeForkTransitionThreshold(
    blockNumber: conf.mergeForkBlock,
    ttd: conf.terminalTotalDifficulty,
    ttdPassed: conf.terminalTotalDifficultyPassed
  )

func toForkTransitionTable*(conf: ChainConfig): ForkTransitionTable =
  # We used to auto-generate this code from a list of
  # field names, but it doesn't seem worthwhile anymore
  # (now that there's irregularity due to block-based vs
  # timestamp-based forking).
  result.blockNumberThresholds[Frontier      ] = some(0.toBlockNumber)
  result.blockNumberThresholds[Homestead     ] = conf.homesteadBlock
  result.blockNumberThresholds[DAOFork       ] = conf.daoForkBlock
  result.blockNumberThresholds[Tangerine     ] = conf.eip150Block
  result.blockNumberThresholds[Spurious      ] = conf.eip158Block
  result.blockNumberThresholds[Byzantium     ] = conf.byzantiumBlock
  result.blockNumberThresholds[Constantinople] = conf.constantinopleBlock
  result.blockNumberThresholds[Petersburg    ] = conf.petersburgBlock
  result.blockNumberThresholds[Istanbul      ] = conf.istanbulBlock
  result.blockNumberThresholds[MuirGlacier   ] = conf.muirGlacierBlock
  result.blockNumberThresholds[Berlin        ] = conf.berlinBlock
  result.blockNumberThresholds[London        ] = conf.londonBlock
  result.blockNumberThresholds[ArrowGlacier  ] = conf.arrowGlacierBlock
  result.blockNumberThresholds[GrayGlacier   ] = conf.grayGlacierBlock
  result.mergeForkTransitionThreshold          = conf.mergeForkTransitionThreshold
  result.timeThresholds[Shanghai] = conf.shanghaiTime
  result.timeThresholds[Cancun] = conf.cancunTime
  result.timeThresholds[Prague] = conf.pragueTime

func populateFromForkTransitionTable*(conf: ChainConfig, t: ForkTransitionTable) =
  conf.homesteadBlock      = t.blockNumberThresholds[HardFork.Homestead]
  conf.daoForkBlock        = t.blockNumberThresholds[HardFork.DAOFork]
  conf.eip150Block         = t.blockNumberThresholds[HardFork.Tangerine]
  conf.eip155Block         = t.blockNumberThresholds[HardFork.Spurious]
  conf.eip158Block         = t.blockNumberThresholds[HardFork.Spurious]
  conf.byzantiumBlock      = t.blockNumberThresholds[HardFork.Byzantium]
  conf.constantinopleBlock = t.blockNumberThresholds[HardFork.Constantinople]
  conf.petersburgBlock     = t.blockNumberThresholds[HardFork.Petersburg]
  conf.istanbulBlock       = t.blockNumberThresholds[HardFork.Istanbul]
  conf.muirGlacierBlock    = t.blockNumberThresholds[HardFork.MuirGlacier]
  conf.berlinBlock         = t.blockNumberThresholds[HardFork.Berlin]
  conf.londonBlock         = t.blockNumberThresholds[HardFork.London]
  conf.arrowGlacierBlock   = t.blockNumberThresholds[HardFork.ArrowGlacier]
  conf.grayGlacierBlock    = t.blockNumberThresholds[HardFork.GrayGlacier]

  conf.mergeForkBlock          = t.mergeForkTransitionThreshold.blockNumber
  conf.terminalTotalDifficulty = t.mergeForkTransitionThreshold.ttd
  conf.terminalTotalDifficultyPassed = t.mergeForkTransitionThreshold.ttdPassed

  conf.shanghaiTime        = t.timeThresholds[HardFork.Shanghai]
  conf.cancunTime          = t.timeThresholds[HardFork.Cancun]
  conf.pragueTime          = t.timeThresholds[HardFork.Prague]

# ------------------------------------------------------------------------------
# Map HardFork to EVM/EVMC Fork
# ------------------------------------------------------------------------------

const
  ToEVMFork*: array[HardFork, EVMFork] = [
    FkFrontier,       # Frontier
    FkHomestead,      # Homestead
    FkHomestead,      # DAOFork
    FkTangerine,      # Tangerine
    FkSpurious,       # Spurious
    FkByzantium,      # Byzantium
    FkConstantinople, # Constantinople
    FkPetersburg,     # Petersburg
    FkIstanbul,       # Istanbul
    FkIstanbul,       # MuirGlacier
    FkBerlin,         # Berlin
    FkLondon,         # London
    FkLondon,         # ArrowGlacier
    FkLondon,         # GrayGlacier
    FkParis,          # MergeFork
    FkShanghai,       # Shanghai
    FkCancun,         # Cancun
    FkPrague,         # Prague
  ]

# ------------------------------------------------------------------------------
# Block reward helpers
# ------------------------------------------------------------------------------

func eth(n: int): UInt256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

const
  eth5 = 5.eth
  eth3 = 3.eth
  eth2 = 2.eth
  eth0 = 0.u256

  BlockRewards*: array[HardFork, UInt256] = [
    eth5, # Frontier
    eth5, # Homestead
    eth5, # DAOFork
    eth5, # Tangerine
    eth5, # Spurious
    eth3, # Byzantium
    eth2, # Constantinople
    eth2, # Petersburg
    eth2, # Istanbul
    eth2, # MuirGlacier
    eth2, # Berlin
    eth2, # London
    eth2, # ArrowGlacier
    eth2, # GrayGlacier
    eth0, # MergeFork
    eth0, # Shanghai
    eth0, # Cancun
    eth0, # Prague
  ]

# ------------------------------------------------------------------------------
# Fork ID helpers
# ------------------------------------------------------------------------------
type
  ForkIdCalculator* = object
    byBlock: seq[uint64]
    byTime: seq[uint64]
    genesisCRC: uint32

func newID*(calc: ForkIdCalculator, head, time: uint64): ForkID =
  var hash = calc.genesisCRC
  for fork in calc.byBlock:
    if fork <= head:
      # Fork already passed, checksum the previous hash and the fork number
      hash = crc32(hash, fork.toBytesBE)
      continue
    return (hash, fork)

  for fork in calc.byTime:
    if fork <= time:
      # Fork already passed, checksum the previous hash and fork timestamp
      hash = crc32(hash, fork.toBytesBE)
      continue
    return (hash, fork)

  (hash, 0'u64)

func initForkIdCalculator*(map: ForkTransitionTable,
                           genesisCRC: uint32,
                           genesisTime: uint64): ForkIdCalculator =

  # Extract the fork rule block number aggregate it
  var forksByBlock: seq[uint64]
  for fork, val in map.blockNumberThresholds:
    if val.isNone: continue
    let val64 = val.get.truncate(uint64)
    if forksByBlock.len == 0:
      forksByBlock.add val64
    elif forksByBlock[^1] != val64:
      # Deduplicate fork identifiers applying multiple forks
      forksByBlock.add val64

  if map.mergeForkTransitionThreshold.blockNumber.isSome:
    let val64 = map.mergeForkTransitionThreshold.blockNumber.get.truncate(uint64)
    if forksByBlock.len == 0:
      forksByBlock.add val64
    elif forksByBlock[^1] != val64:
      # Deduplicate fork identifiers applying multiple forks
      forksByBlock.add val64

  # Skip any forks in block 0, that's the genesis ruleset
  if forksByBlock.len > 0 and forksByBlock[0] == 0:
    forksByBlock.delete(0)

  # Extract the fork rule timestamp number aggregate it
  var forksByTime: seq[uint64]
  for fork, val in map.timeThresholds:
    if val.isNone: continue
    let val64 = val.get.uint64
    if forksByTime.len == 0:
      forksByTime.add val64
    elif forksByTime[^1] != val64:
      forksByTime.add val64

  # Skip any forks before genesis.
  while forksByTime.len > 0 and forksByTime[0] <= genesisTime:
    forksByTime.delete(0)

  result.genesisCRC = genesisCRC
  result.byBlock = system.move(forksByBlock)
  result.byTime = system.move(forksByTime)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
