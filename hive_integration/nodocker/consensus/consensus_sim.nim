# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json, strutils, times],
  results,
  chronicles,
  ../../../execution_chain/core/chain,
  ../../../execution_chain/core/block_import,
  ../../../execution_chain/common,
  ../sim_utils,
  ./extract_consensus_data

proc processChainData(cd: ChainData, taskPool: Taskpool): TestStatus =
  let
    networkId = NetworkId(cd.params.config.chainId)
    com = CommonRef.new(newCoreDbRef DefaultDbMemory,
      taskPool,
      networkId,
      cd.params
    )

  let c = ForkedChainRef.init(com)

  for bytes in cd.blocksRlp:
    # ignore return value here
    # because good blocks maybe interleaved with
    # bad blocks
    discard importRlpBlocks(bytes, c, finalize = true)

  let blockHash = $c.latestHash
  if blockHash == cd.lastBlockHash:
    TestStatus.OK
  else:
    trace "block hash not equal",
      got=blockHash,
      number=c.latestHeader.number,
      expected=cd.lastBlockHash
    TestStatus.Failed

const unsupportedTests = [
  # total difficulty cases which is not supported in ForkedChain
  "lotsOfBranchesOverrideAtTheMiddle.json",
  "sideChainWithMoreTransactions.json",
  "uncleBlockAtBlock3afterBlock4.json",
  "CallContractFromNotBestBlock.json",
  "ChainAtoChainB_difficultyB.json",
  "ForkStressTest.json",
  "blockChainFrontierWithLargerTDvsHomesteadBlockchain.json",
  "blockChainFrontierWithLargerTDvsHomesteadBlockchain2.json",
  "lotsOfLeafs.json",

  # super slow case
  "loopMul.json",

  # zig zag case, similar with total difficulty above
  "lotsOfBranchesOverrideAtTheEnd.json",
  "DaoTransactions.json",
  "ChainAtoChainBtoChainAtoChainB.json",
  ]

proc main() =
  const basePath = "tests/fixtures/eth_tests/BlockchainTests"
  var stat: SimStat
  let taskPool = Taskpool.new()
  let start = getTime()

  for fileName in walkDirRec(basePath):
    if not fileName.endsWith(".json"):
      continue

    let (_, name) = fileName.splitPath()
    if name in unsupportedTests:
      let n = json.parseFile(fileName)
      stat.skipped += n.len
      continue

    debugEcho fileName
    let n = json.parseFile(fileName)
    for caseName, unit in n:
      let cd = extractChainData(unit)
      let status = processChainData(cd, taskPool)
      stat.inc(caseName, status)

  let elpd = getTime() - start
  print(stat, elpd, "consensus")

main()
