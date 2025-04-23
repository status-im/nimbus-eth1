# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./engine_spec,
  ../../../../execution_chain/common/hardforks

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
  forkConfig.londonBlock = Opt.some(1'u64)
  forkConfig.mergeNetsplitBlock = Opt.some(1'u64)

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
