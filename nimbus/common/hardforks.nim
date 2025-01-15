# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[strutils],
  eth/common/[headers],
  stew/endians2,
  json_serialization,
  ../utils/utils,
  ./evmforks

{.push raises: [].}

type
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
    Osaka

const lastPurelyBlockNumberBasedFork* = GrayGlacier
# MergeFork is special because of TTD.
const firstTimeBasedFork* = Shanghai


type
  MergeForkTransitionThreshold* = object
    number*: Opt[BlockNumber]
    ttd*: Opt[DifficultyInt]

  ForkTransitionTable* = object
    blockNumberThresholds*: array[Frontier..GrayGlacier, Opt[BlockNumber]]
    mergeForkTransitionThreshold*: MergeForkTransitionThreshold
    timeThresholds*: array[Shanghai..Osaka, Opt[EthTime]]

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
    number*: BlockNumber
    time*: Opt[EthTime]
    td*: Opt[DifficultyInt]

func forkDeterminationInfo*(n: BlockNumber): ForkDeterminationInfo =
  # FIXME: All callers of this function are suspect; I'm guess we should
  # always be using both block number and time. But we have a few places,
  # like various tests, where we only have block number and the tests are
  # meant for pre-Merge forks, so maybe those are okay.
  ForkDeterminationInfo(
    number: n, time: Opt.none(EthTime), td: Opt.none(DifficultyInt))

func forkDeterminationInfo*(n: BlockNumber, t: EthTime): ForkDeterminationInfo =
  ForkDeterminationInfo(
    number: n, time: Opt.some(t), td: Opt.none(DifficultyInt))

func forkDeterminationInfo*(header: Header): ForkDeterminationInfo =
  # FIXME-Adam-mightAlsoNeedTTD?
  forkDeterminationInfo(header.number, header.timestamp)

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
    number: adjustForNextBlock(f.number),
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
    map.blockNumberThresholds[fork].isSome and forkDeterminer.number >= map.blockNumberThresholds[fork].get
  elif fork == MergeFork:
    # MergeFork is a special case that can use either block number or ttd;
    # block number > ttd takes precedence.
    let t = map.mergeForkTransitionThreshold
    if t.number.isSome:
      forkDeterminer.number >= t.number.get
    elif t.ttd.isSome and forkDeterminer.td.isSome:
      forkDeterminer.td.get >= t.ttd.get
    else:
      false
  elif fork <= HardFork.high:
    map.timeThresholds[fork].isSome and forkDeterminer.time.isSome and forkDeterminer.time.get >= map.timeThresholds[fork].get
  else:
    raise newException(Defect, "Why is this hard fork not in one of the above categories?")

const
  BlobScheduleTable*: array[Cancun..HardFork.high, string] = [
    "cancun",
    "prague",
    "osaka"
  ]

type
  BlobSchedule* = object
    target*: uint64
    max*   : uint64

  # if you add more fork block
  # please update forkBlockField constant too
  ChainConfig* = ref object
    chainId*            : ChainId
    homesteadBlock*     : Opt[BlockNumber]
    daoForkBlock*       : Opt[BlockNumber]
    daoForkSupport*     : bool
    eip150Block*        : Opt[BlockNumber]
    eip150Hash*         : Hash32
    eip155Block*        : Opt[BlockNumber]
    eip158Block*        : Opt[BlockNumber]
    byzantiumBlock*     : Opt[BlockNumber]
    constantinopleBlock*: Opt[BlockNumber]
    petersburgBlock*    : Opt[BlockNumber]
    istanbulBlock*      : Opt[BlockNumber]
    muirGlacierBlock*   : Opt[BlockNumber]
    berlinBlock*        : Opt[BlockNumber]
    londonBlock*        : Opt[BlockNumber]
    arrowGlacierBlock*  : Opt[BlockNumber]
    grayGlacierBlock*   : Opt[BlockNumber]

    # posBlock does not participate in ForkId
    # calculation, and in config file
    # specially crafted for network depends
    # solely on TTD  for transition to PoS
    # e.g. MainNet, but now has pass the transition
    posBlock*
      {.dontSerialize.} : Opt[BlockNumber]

    mergeNetsplitBlock* : Opt[BlockNumber]

    shanghaiTime*       : Opt[EthTime]
    cancunTime*         : Opt[EthTime]
    pragueTime*         : Opt[EthTime]
    osakaTime*          : Opt[EthTime]

    terminalTotalDifficulty*: Opt[UInt256]
    depositContractAddress*: Opt[Address]
    blobSchedule*       : array[Cancun..HardFork.high, Opt[BlobSchedule]]

  # These are used for checking that the values of the fields
  # are in a valid order.
  BlockNumberBasedForkOptional* = object
    name*: string
    number*: Opt[BlockNumber]
  TimeBasedForkOptional* = object
    name*: string
    time*: Opt[EthTime]

func countTimeFields(): int {.compileTime.} =
  var z = ChainConfig()
  for name, _ in fieldPairs(z[]):
    if name.endsWith("Time"):
      inc result

func countBlockFields(): int {.compileTime.} =
  var z = ChainConfig()
  for name, _ in fieldPairs(z[]):
    if name.endsWith("Block"):
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
    if name.endsWith("Block"):
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
    number: conf.mergeNetsplitBlock,
    ttd: conf.terminalTotalDifficulty,
  )

func toForkTransitionTable*(conf: ChainConfig): ForkTransitionTable =
  # We used to auto-generate this code from a list of
  # field names, but it doesn't seem worthwhile anymore
  # (now that there's irregularity due to block-based vs
  # timestamp-based forking).
  result.blockNumberThresholds[Frontier      ] = Opt.some(0.BlockNumber)
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
  result.timeThresholds[Osaka] = conf.osakaTime

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

  conf.mergeNetsplitBlock      = t.mergeForkTransitionThreshold.number
  conf.terminalTotalDifficulty = t.mergeForkTransitionThreshold.ttd

  conf.shanghaiTime        = t.timeThresholds[HardFork.Shanghai]
  conf.cancunTime          = t.timeThresholds[HardFork.Cancun]
  conf.pragueTime          = t.timeThresholds[HardFork.Prague]
  conf.osakaTime           = t.timeThresholds[HardFork.Osaka]

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
    FkOsaka,          # Osaka
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
    let val64 = val.get
    if forksByBlock.len == 0:
      forksByBlock.add val64
    elif forksByBlock[^1] != val64:
      # Deduplicate fork identifiers applying multiple forks
      forksByBlock.add val64

  if map.mergeForkTransitionThreshold.number.isSome:
    let val64 = map.mergeForkTransitionThreshold.number.get
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
