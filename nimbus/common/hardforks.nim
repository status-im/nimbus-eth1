# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options, times],
  eth/common,
  json_serialization,
  ../utils/utils,
  ./evmforks

{.push raises: [].}

type
  ConsensusType* {.pure.} = enum
    # Proof of Work
    # algorithm: Ethash
    POW

    # Proof of Authority
    # algorithm: Clique
    POA

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

  CliqueOptions* = object
    epoch* : Option[int]
    period*: Option[int]

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
    mergeForkBlock*     : Option[BlockNumber]
    shanghaiBlock*      : Option[BlockNumber]
    cancunBlock*        : Option[BlockNumber]

    clique*             : CliqueOptions
    terminalTotalDifficulty*: Option[UInt256]
    consensusType*
      {.dontSerialize.} : ConsensusType

  ForkTransitionTable* = array[HardFork, Option[BlockNumber]]
  ForkOptional* = object
    name*: string
    number*: Option[BlockNumber]

  ForkDeterminationInfo* = BlockNumber


proc blockNumberToForkDeterminationInfo*(n: BlockNumber): ForkDeterminationInfo =
  n

proc forkDeterminationInfo*(n: BlockNumber, t: EthTime): ForkDeterminationInfo =
  n

proc forkDeterminationInfoForHeader*(header: BlockHeader): ForkDeterminationInfo =
  forkDeterminationInfo(header.blockNumber, header.timestamp)

proc adjustForNextBlock*(n: BlockNumber): BlockNumber =
  n + 1

proc adjustForNextBlock*(t: EthTime): EthTime =
  fromUnix(t.toUnix + 12)


const
  # this table is used for generate
  # code at compile time to check
  # the order of blok number in ChainConfig
  forkBlockField* = [
    "homesteadBlock",
    "daoForkBlock",
    "eip150Block",
    "eip155Block",
    "eip158Block",
    "byzantiumBlock",
    "constantinopleBlock",
    "petersburgBlock",
    "istanbulBlock",
    "muirGlacierBlock",
    "berlinBlock",
    "londonBlock",
    "arrowGlacierBlock",
    "grayGlacierBlock",
    "mergeForkBlock",
    "shanghaiBlock",
    "cancunBlock",
  ]

  # this table is used to generate
  # code to build fork to block number
  # array
  forkBlockNumber* = [
    Homestead: "homesteadBlock",
    DAOFork: "daoForkBlock",
    Tangerine: "eip150Block",
    Spurious: "eip158Block",
    Byzantium: "byzantiumBlock",
    Constantinople: "constantinopleBlock",
    Petersburg: "petersburgBlock",
    Istanbul: "istanbulBlock",
    MuirGlacier: "muirGlacierBlock",
    Berlin: "berlinBlock",
    London: "londonBlock",
    ArrowGlacier: "arrowGlacierBlock",
    GrayGlacier: "grayGlacierBlock",
    MergeFork: "mergeForkBlock",
    Shanghai: "shanghaiBlock",
    Cancun: "cancunBlock",
  ]

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
  ]

# ------------------------------------------------------------------------------
# Fork ID helpers
# ------------------------------------------------------------------------------

func toNextFork(n: Option[BlockNumber]): uint64 =
  if n.isSome:
    n.get.truncate(uint64)
  else:
    0'u64

func getNextFork(c: ChainConfig, fork: HardFork): uint64 =
  let next: array[HardFork, uint64] = [
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
    toNextFork(c.arrowGlacierBlock),
    toNextFork(c.grayGlacierBlock),
    toNextFork(c.mergeForkBlock),
    toNextFork(c.shanghaiBlock),
    toNextFork(c.cancunBlock),
  ]

  if fork == high(HardFork):
    result = 0
    return

  result = next[fork]
  for x in fork..high(HardFork):
    if result != next[x]:
      result = next[x]
      break

func calculateForkId(c: ChainConfig, fork: HardFork,
                     prevCRC: uint32, prevFork: uint64): ForkID =
  result.nextFork = c.getNextFork(fork)

  if result.nextFork != prevFork:
    result.crc = crc32(prevCRC, toBytesBE(prevFork))
  else:
    result.crc = prevCRC

func calculateForkIds*(c: ChainConfig,
                      genesisCRC: uint32): array[HardFork, ForkID] =
  var prevCRC = genesisCRC
  var prevFork = c.getNextFork(Frontier)

  for fork in HardFork:
    result[fork] = calculateForkId(c, fork, prevCRC, prevFork)
    prevFork = result[fork].nextFork
    prevCRC = result[fork].crc

# ------------------------------------------------------------------------------
# BlockNumber + TD comparator
# ------------------------------------------------------------------------------

type
  BlockToForkFunc* = proc(data, number, td: UInt256): bool
    {.gcsafe, noSideEffect, nimcall, raises: [Defect, CatchableError].}

  BlockToFork* = object
    # `data` can be blockNumber or TTD
    data*  : UInt256
    toFork*: BlockToForkFunc

  BlockToForks* = array[HardFork, BlockToFork]

func forkTrue(data, number, td: UInt256): bool
  {.gcsafe, nimcall, raises: [].} =
  # frontier always return true
  true

func forkFalse(data, number, td: UInt256): bool
  {.gcsafe, nimcall, raises: [].} =
  # forkBlock.isNone always return false
  false

func forkMaybe(data, number, td: UInt256): bool
  {.gcsafe, nimcall, raises: [].} =
  # data is a blockNumber
  number >= data

func mergeMaybe(data, number, td: UInt256): bool
  {.gcsafe, nimcall, raises: [].} =
  # data is a TTD
  td >= data

proc blockToForks*(conf: ChainConfig, map: ForkTransitionTable): BlockToForks =
  # between Frontier and latest HardFork
  # can be a match or not
  for fork, number in map:
    if number.isSome:
      result[fork].data = number.get()
      result[fork].toFork = forkMaybe
    else:
      result[fork].toFork = forkFalse

  # Frontier always return true
  result[Frontier].toFork = forkTrue

  # special case for MergeFork
  # if MergeForkBlock.isSome, it takes precedence over TTD
  # if MergeForkBlock.isNone, compare TD with TTD
  if map[MergeFork].isNone and
     conf.terminalTotalDifficulty.isSome:
    result[MergeFork].data = conf.terminalTotalDifficulty.get()
    result[MergeFork].toFork = mergeMaybe

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
