# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common,
  ../../nimbus/[chain_config, forks],
  ./types

export
  types

func getChainConfig*(network: string, c: ChainConfig) =
  const
    H = high(BlockNumber)
    Zero = 0.toBlockNumber
    Five = 5.toBlockNumber

  proc assignNumber(c: ChainConfig,
                    fork: Fork, n: BlockNumber) =
    var number: array[Fork, BlockNumber]
    var z = low(Fork)
    while z < fork:
      number[z] = Zero
      z = z.succ
    number[fork] = n
    z = high(Fork)
    while z > fork:
      number[z] = H
      z = z.pred

    c.homesteadBlock      = number[FkHomestead]
    c.daoForkBlock        = number[FkHomestead]
    c.eip150Block         = number[FkTangerine]
    c.eip155Block         = number[FkSpurious]
    c.eip158Block         = number[FkSpurious]
    c.byzantiumBlock      = number[FkByzantium]
    c.constantinopleBlock = number[FkConstantinople]
    c.petersburgBlock     = number[FkPetersburg]
    c.istanbulBlock       = number[FkIstanbul]
    c.muirGlacierBlock    = number[FkBerlin]
    c.berlinBlock         = number[FkBerlin]
    c.londonBlock         = number[FkLondon]
    c.arrowGlacierBlock   = number[FkLondon]
    c.grayGlacierBlock    = number[FkLondon]
    c.mergeForkBlock      = number[FkParis]
    c.shanghaiBlock       = number[FkShanghai]
    c.cancunBlock         = number[FkCancun]

  c.daoForkSupport = false
  c.chainId = 1.ChainId
  c.terminalTotalDifficulty = none(UInt256)

  case network
  of $TestFork.Frontier:
    c.assignNumber(FkFrontier, Zero)
  of $TestFork.Homestead:
    c.assignNumber(FkHomestead, Zero)
  of $TestFork.EIP150:
    c.assignNumber(FkTangerine, Zero)
  of $TestFork.EIP158:
    c.assignNumber(FkSpurious, Zero)
  of $TestFork.Byzantium:
    c.assignNumber(FkByzantium, Zero)
  of $TestFork.Constantinople:
    c.assignNumber(FkConstantinople, Zero)
  of $TestFork.ConstantinopleFix:
    c.assignNumber(FkPetersburg, Zero)
  of $TestFork.Istanbul:
    c.assignNumber(FkIstanbul, Zero)
  of $TestFork.FrontierToHomesteadAt5:
    c.assignNumber(FkHomestead, Five)
  of $TestFork.HomesteadToEIP150At5:
    c.assignNumber(FkTangerine, Five)
  of $TestFork.HomesteadToDaoAt5:
    c.assignNumber(FkHomestead, Zero)
    c.daoForkBlock = Five
    c.daoForkSupport = true
  of $TestFork.EIP158ToByzantiumAt5:
    c.assignNumber(FkByzantium, Five)
  of $TestFork.ByzantiumToConstantinopleAt5:
    c.assignNumber(FkPetersburg, Five)
  of $TestFork.ByzantiumToConstantinopleFixAt5:
    c.assignNumber(FkPetersburg, Five)
    c.constantinopleBlock = Five
  of $TestFork.ConstantinopleFixToIstanbulAt5:
    c.assignNumber(FkIstanbul, Five)
  of $TestFork.Berlin:
    c.assignNumber(FkBerlin, Zero)
  of $TestFork.BerlinToLondonAt5:
    c.assignNumber(FkLondon, Five)
  of $TestFork.London:
    c.assignNumber(FkLondon, Zero)
    c.arrowGlacierBlock = H
    c.grayGlacierBlock = H
  of $TestFork.ArrowGlacier:
    c.assignNumber(FkLondon, Zero)
    c.grayGlacierBlock = H
  of $TestFork.GrayGlacier:
    c.assignNumber(FkLondon, Zero)
    c.grayGlacierBlock = Zero
  of $TestFork.Merge:
    c.assignNumber(FkParis, Zero)
    c.terminalTotalDifficulty = some(0.u256)
  of $TestFork.ArrowGlacierToMergeAtDiffC0000:
    c.assignNumber(FkParis, H)
    c.terminalTotalDifficulty = some(0xC0000.u256)
  of $TestFork.Shanghai:
    c.assignNumber(FkShanghai, Zero)
    c.terminalTotalDifficulty = some(0.u256)
  of $TestFork.Cancun:
    c.assignNumber(FkCancun, Zero)
    c.terminalTotalDifficulty = some(0.u256)
  else:
    raise newException(ValueError, "unsupported network " & network)

func getChainConfig*(network: string): ChainConfig =
  let c = ChainConfig()
  getChainConfig(network, c)
  result = c
