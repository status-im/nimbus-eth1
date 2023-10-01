import
  std/[options],
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

  cl.blockTimestampIncrement = some(s.getBlockTimeIncrements())

func getMainFork*(s: BaseSpec): string =
  let mainFork = s.mainFork
  if mainFork == "":
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

func getForkConfig*(s: BaseSpec): ChainConfig =
  let
    forkTime = s.getForkTime()
    previousForkTime = s.previousForkTime
    mainFork = s.getMainFork()
    forkConfig = getChainConfig(mainFork)
    genesisTimestamp = s.getGenesisTimestamp()

  doAssert(previousForkTime <= forkTime,
    "previous fork time cannot be greater than fork time")

  if mainFork == ForkParis:
    let cond = forkTime > genesisTimestamp or previousForkTime != 0
    doAssert(not cond, "Cannot configure a fork before Paris, skip test")
  elif mainFork == ForkShanghai:
    doAssert(previousForkTime == 0, "Cannot configure a fork before Shanghai")
    forkConfig.shanghaiTime = some(forkTime.EthTime)
  elif mainFork == ForkCancun:
    forkConfig.shanghaiTime = some(previousForkTime.EthTime)
    forkConfig.cancunTime = some(forkTime.EthTime)
  else:
    doAssert(false, "unknown fork: " & mainFork)

  return forkConfig
