import
  ./engine_spec,
  ../../../../nimbus/common/hardforks

# Runs a sanity test on a post Merge fork where a previous fork's (London) number is not zero
type
  NonZeroPreMergeFork* = ref object of EngineSpec

method withMainFork(cs: NonZeroPreMergeFork, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: NonZeroPreMergeFork): string =
  "Pre-Merge Fork Number > 0"

method getForkConfig*(cs: NonZeroPreMergeFork): ChainConfig =
  let forkConfig = procCall getForkConfig(BaseSpec(cs))
  if forkConfig.isNil:
    return nil
    
  # Merge fork & pre-merge happen at block 1
  forkConfig.londonBlock = some(1.u256)
  forkConfig.mergeForkBlock = some(1.u256)

  # Post-merge fork happens at block 2
  let mainFork = BaseSpec(cs).getMainFork()
  if mainFork == ForkCancun:
    forkConfig.shanghaiTime = forkConfig.cancunTime

  return forkConfig

method execute(cs: NonZeroPreMergeFork, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Simply produce a couple of blocks without transactions (if London is not active at genesis
  # we can't send type-2 transactions) and check that the chain progresses without issues
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  return true
