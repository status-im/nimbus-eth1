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
  ../../nimbus/common/common,
  ./types

export
  types

func getChainConfig*(network: string, c: ChainConfig) =
  const
    Zero = 0.toBlockNumber
    Five = 5.toBlockNumber

  proc assignNumber(c: ChainConfig,
                    fork: HardFork, n: BlockNumber) =
    var number: array[HardFork, Option[BlockNumber]]
    var z = low(HardFork)
    while z < fork:
      number[z] = some(Zero)
      z = z.succ
    number[fork] = some(n)
    z = high(HardFork)
    while z > fork:
      number[z] = none(BlockNumber)
      z = z.pred

    c.homesteadBlock      = number[HardFork.Homestead]
    c.daoForkBlock        = number[HardFork.DAOFork]
    c.eip150Block         = number[HardFork.Tangerine]
    c.eip155Block         = number[HardFork.Spurious]
    c.eip158Block         = number[HardFork.Spurious]
    c.byzantiumBlock      = number[HardFork.Byzantium]
    c.constantinopleBlock = number[HardFork.Constantinople]
    c.petersburgBlock     = number[HardFork.Petersburg]
    c.istanbulBlock       = number[HardFork.Istanbul]
    c.muirGlacierBlock    = number[HardFork.MuirGlacier]
    c.berlinBlock         = number[HardFork.Berlin]
    c.londonBlock         = number[HardFork.London]
    c.arrowGlacierBlock   = number[HardFork.ArrowGlacier]
    c.grayGlacierBlock    = number[HardFork.GrayGlacier]
    c.mergeForkBlock      = number[HardFork.MergeFork]
    c.shanghaiBlock       = number[HardFork.Shanghai]
    # FIXME-Adam: I don't understand how these tests are supposed
    # to work. Will they specify timestamps for Shanghai/Cancun?
    # c.cancunBlock         = number[HardFork.Cancun]

  c.daoForkSupport = false
  c.chainId = 1.ChainId
  c.terminalTotalDifficulty = none(UInt256)

  case network
  of $TestFork.Frontier:
    c.assignNumber(HardFork.Frontier, Zero)
  of $TestFork.Homestead:
    c.assignNumber(HardFork.Homestead, Zero)
  of $TestFork.EIP150:
    c.assignNumber(HardFork.Tangerine, Zero)
  of $TestFork.EIP158:
    c.assignNumber(HardFork.Spurious, Zero)
  of $TestFork.Byzantium:
    c.assignNumber(HardFork.Byzantium, Zero)
  of $TestFork.Constantinople:
    c.assignNumber(HardFork.Constantinople, Zero)
  of $TestFork.ConstantinopleFix:
    c.assignNumber(HardFork.Petersburg, Zero)
  of $TestFork.Istanbul:
    c.assignNumber(HardFork.Istanbul, Zero)
  of $TestFork.FrontierToHomesteadAt5:
    c.assignNumber(HardFork.Homestead, Five)
  of $TestFork.HomesteadToEIP150At5:
    c.assignNumber(HardFork.Tangerine, Five)
  of $TestFork.HomesteadToDaoAt5:
    c.assignNumber(HardFork.DAOFork, Five)
    c.daoForkSupport = true
  of $TestFork.EIP158ToByzantiumAt5:
    c.assignNumber(HardFork.Byzantium, Five)
  of $TestFork.ByzantiumToConstantinopleAt5:
    c.assignNumber(HardFork.Constantinople, Five)
  of $TestFork.ByzantiumToConstantinopleFixAt5:
    c.assignNumber(HardFork.Petersburg, Five)
    c.constantinopleBlock = some(Five)
  of $TestFork.ConstantinopleFixToIstanbulAt5:
    c.assignNumber(HardFork.Istanbul, Five)
  of $TestFork.Berlin:
    c.assignNumber(HardFork.Berlin, Zero)
  of $TestFork.BerlinToLondonAt5:
    c.assignNumber(HardFork.London, Five)
  of $TestFork.London:
    c.assignNumber(HardFork.London, Zero)
  of $TestFork.ArrowGlacier:
    c.assignNumber(HardFork.ArrowGlacier, Zero)
  of $TestFork.GrayGlacier:
    c.assignNumber(HardFork.GrayGlacier, Zero)
  of $TestFork.Merge:
    c.assignNumber(HardFork.MergeFork, Zero)
  of $TestFork.ArrowGlacierToMergeAtDiffC0000:
    c.assignNumber(HardFork.GrayGlacier, Zero)
    c.terminalTotalDifficulty = some(0xC0000.u256)
  of $TestFork.Shanghai:
    c.assignNumber(HardFork.Shanghai, Zero)
  of $TestFork.Cancun:
    c.assignNumber(HardFork.Cancun, Zero)
  else:
    raise newException(ValueError, "unsupported network " & network)

func getChainConfig*(network: string): ChainConfig =
  let c = ChainConfig()
  getChainConfig(network, c)
  result = c
