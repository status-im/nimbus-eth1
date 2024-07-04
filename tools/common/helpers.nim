# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../nimbus/common/common,
  ./types

export
  types

const
  BlockNumberZero = 0.BlockNumber
  BlockNumberFive = 5.BlockNumber
  TimeZero = EthTime(0)

proc createForkTransitionTable(transitionFork: HardFork,
                               b: Opt[BlockNumber],
                               t: Opt[EthTime],
                               ttd: Opt[DifficultyInt]): ForkTransitionTable =

  proc blockNumberToUse(f: HardFork): Opt[BlockNumber] =
    if f < transitionFork:
      Opt.some(BlockNumberZero)
    elif f == transitionFork:
      b
    else:
      Opt.none(BlockNumber)

  proc timeToUse(f: HardFork): Opt[EthTime] =
    if f < transitionFork:
      Opt.some(TimeZero)
    elif f == transitionFork:
      t
    else:
      Opt.none(EthTime)

  for f in low(HardFork) .. lastPurelyBlockNumberBasedFork:
    result.blockNumberThresholds[f] = blockNumberToUse(f)

  result.mergeForkTransitionThreshold.number = blockNumberToUse(HardFork.MergeFork)
  result.mergeForkTransitionThreshold.ttd = ttd

  for f in firstTimeBasedFork .. high(HardFork):
    result.timeThresholds[f] = timeToUse(f)

proc assignNumber(c: ChainConfig, transitionFork: HardFork, n: BlockNumber) =
  let table = createForkTransitionTable(transitionFork,
    Opt.some(n), Opt.none(EthTime), Opt.none(DifficultyInt))
  c.populateFromForkTransitionTable(table)

proc assignTime(c: ChainConfig, transitionFork: HardFork, t: EthTime) =
  let table = createForkTransitionTable(transitionFork,
    Opt.none(BlockNumber), Opt.some(t), Opt.none(DifficultyInt))
  c.populateFromForkTransitionTable(table)

func getChainConfig*(network: string, c: ChainConfig) =
  c.daoForkSupport = false
  c.chainId = 1.ChainId
  c.terminalTotalDifficulty = Opt.none(UInt256)

  case network
  of $TestFork.Frontier:
    c.assignNumber(HardFork.Frontier, BlockNumberZero)
  of $TestFork.Homestead:
    c.assignNumber(HardFork.Homestead, BlockNumberZero)
  of $TestFork.EIP150:
    c.assignNumber(HardFork.Tangerine, BlockNumberZero)
  of $TestFork.EIP158:
    c.assignNumber(HardFork.Spurious, BlockNumberZero)
  of $TestFork.Byzantium:
    c.assignNumber(HardFork.Byzantium, BlockNumberZero)
  of $TestFork.Constantinople:
    c.assignNumber(HardFork.Constantinople, BlockNumberZero)
  of $TestFork.ConstantinopleFix:
    c.assignNumber(HardFork.Petersburg, BlockNumberZero)
  of $TestFork.Istanbul:
    c.assignNumber(HardFork.Istanbul, BlockNumberZero)
  of $TestFork.FrontierToHomesteadAt5:
    c.assignNumber(HardFork.Homestead, BlockNumberFive)
  of $TestFork.HomesteadToEIP150At5:
    c.assignNumber(HardFork.Tangerine, BlockNumberFive)
  of $TestFork.HomesteadToDaoAt5:
    c.assignNumber(HardFork.DAOFork, BlockNumberFive)
    c.daoForkSupport = true
  of $TestFork.EIP158ToByzantiumAt5:
    c.assignNumber(HardFork.Byzantium, BlockNumberFive)
  of $TestFork.ByzantiumToConstantinopleAt5:
    c.assignNumber(HardFork.Constantinople, BlockNumberFive)
  of $TestFork.ByzantiumToConstantinopleFixAt5:
    c.assignNumber(HardFork.Petersburg, BlockNumberFive)
    c.constantinopleBlock = Opt.some(BlockNumberFive)
  of $TestFork.ConstantinopleFixToIstanbulAt5:
    c.assignNumber(HardFork.Istanbul, BlockNumberFive)
  of $TestFork.Berlin:
    c.assignNumber(HardFork.Berlin, BlockNumberZero)
  of $TestFork.BerlinToLondonAt5:
    c.assignNumber(HardFork.London, BlockNumberFive)
  of $TestFork.London:
    c.assignNumber(HardFork.London, BlockNumberZero)
  of $TestFork.ArrowGlacier:
    c.assignNumber(HardFork.ArrowGlacier, BlockNumberZero)
  of $TestFork.GrayGlacier:
    c.assignNumber(HardFork.GrayGlacier, BlockNumberZero)
  of $TestFork.Merge, $TestFork.Paris:
    c.assignNumber(HardFork.MergeFork, BlockNumberZero)
  of $TestFork.ArrowGlacierToParisAtDiffC0000:
    c.assignNumber(HardFork.GrayGlacier, BlockNumberZero)
    c.terminalTotalDifficulty = Opt.some(0xC0000.u256)
  of $TestFork.Shanghai:
    c.assignTime(HardFork.Shanghai, TimeZero)
  of $TestFork.ParisToShanghaiAtTime15k:
    c.assignTime(HardFork.Shanghai, EthTime(15000))
  of $TestFork.Cancun:
    c.assignTime(HardFork.Cancun, TimeZero)
  of $TestFork.ShanghaiToCancunAtTime15k:
    c.assignTime(HardFork.Cancun, EthTime(15000))
  of $TestFork.Prague:
    c.assignTime(HardFork.Prague, TimeZero)
  else:
    raise newException(ValueError, "unsupported network " & network)

func getChainConfig*(network: string): ChainConfig =
  let c = ChainConfig()
  getChainConfig(network, c)
  result = c
