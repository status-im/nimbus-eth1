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
  std/strutils,
  ./engine_spec,
  ../../../../nimbus/common/hardforks

type
  ForkIDSpec* = ref object of EngineSpec
    produceBlocksBeforePeering*: int

method withMainFork(cs: ForkIDSpec, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ForkIDSpec): string =
  var name = "Fork ID: Genesis at $1, $2 at $3" % [$cs.getGenesistimestamp(), $cs.mainFork, $cs.forkTime]
  if cs.previousForkTime != 0:
    name.add ", $1 at $2" % [$cs.mainFork.pred, $cs.previousForkTime]

  if cs.produceBlocksBeforePeering > 0:
    name.add ", Produce $1 blocks before peering" % [$cs.produceBlocksBeforePeering]

  return name

method getForkConfig*(cs: ForkIDSpec): ChainConfig =
  let forkConfig = procCall getForkConfig(BaseSpec(cs))
  if forkConfig.isNil:
    return nil

  # Merge fork happen at block 0
  let mainFork = cs.getMainFork()
  if mainFork == ForkParis:
    forkConfig.mergeForkBlock = some(0.u256)
  return forkConfig

method execute(cs: ForkIDSpec, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test if required
  testCond env.clMock.produceBlocks(cs.produceBlocksBeforePeering, BlockProcessCallbacks())

  # Get client index's enode
  let engine = env.addEngine()
  return true
