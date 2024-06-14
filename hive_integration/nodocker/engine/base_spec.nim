# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common,
  ./clmock,
  ./types,
  ../../../tools/common/helpers,
  ../../../nimbus/common/chain_config

func getBlockTimeIncrements*(s: BaseSpec): int =
  if s.blockTimestampIncrement == 0:
    return 1
  return s.blockTimestampIncrement

proc configureCLMock*(s: BaseSpec, cl: CLMocker) =
  if s.slotsToSafe != 0:
    cl.slotsToSafe = s.slotsToSafe

  if s.slotsToFinalized != 0:
    cl.slotsToFinalized = s.slotsToFinalized

  if s.safeSlotsToImportOptimistically != 0:
    cl.safeSlotsToImportOptimistically = s.safeSlotsToImportOptimistically

  cl.blockTimestampIncrement = Opt.some(s.getBlockTimeIncrements())

func getMainFork*(s: BaseSpec): EngineFork =
  let mainFork = s.mainFork
  if mainFork == ForkNone:
    return ForkParis
  return mainFork

func getGenesisTimestamp*(s: BaseSpec): uint64 =
  var genesisTimestamp = GenesisTimestamp
  if s.genesisTimestamp != 0:
    genesisTimestamp = s.genesisTimestamp
  return genesisTimestamp.uint64

func getBlockTime*(s: BaseSpec, blockNumber: uint64): uint64 =
  return s.getGenesisTimestamp() + blockNumber*s.getBlockTimeIncrements().uint64

func getForkTime*(s: BaseSpec): uint64 =
  var forkTime = s.forkTime
  if s.forkHeight > 0:
    forkTime = s.getBlockTime(s.forkHeight.uint64)
  return forkTime

method getForkConfig*(s: BaseSpec): ChainConfig {.base.} =
  let
    forkTime = s.getForkTime()
    previousForkTime = s.previousForkTime
    mainFork = s.getMainFork()
    forkConfig = getChainConfig($mainFork)
    genesisTimestamp = s.getGenesisTimestamp()

  doAssert(previousForkTime <= forkTime,
    "previous fork time cannot be greater than fork time")

  if mainFork == ForkParis:
    # Cannot configure a fork before Paris, skip test
    if forkTime > genesisTimestamp or previousForkTime != 0:
      debugEcho "forkTime: ", forkTime
      debugEcho "genesisTime: ", genesisTimestamp
      return nil
  elif mainFork == ForkShanghai:
    # Cannot configure a fork before Shanghai
    if previousForkTime != 0:
      return nil
    forkConfig.shanghaiTime = Opt.some(forkTime.EthTime)
  elif mainFork == ForkCancun:
    forkConfig.shanghaiTime = Opt.some(previousForkTime.EthTime)
    forkConfig.cancunTime = Opt.some(forkTime.EthTime)
  else:
    doAssert(false, "unknown fork: " & $mainFork)

  return forkConfig
