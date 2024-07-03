# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json, strutils, times],
  stew/byteutils,
  results,
  chronicles,
  ../../../nimbus/core/chain,
  ../../../nimbus/core/block_import,
  ../../../nimbus/common,
  ../../../nimbus/core/eip4844,
  ../sim_utils,
  ./extract_consensus_data

proc processChainData(cd: ChainData): TestStatus =
  let
    networkId = NetworkId(cd.params.config.chainId)
    com = CommonRef.new(newCoreDbRef DefaultDbMemory,
      networkId,
      cd.params
    )

  com.initializeEmptyDb()

  let c = newForkedChain(com, com.genesisHeader)
  for bytes in cd.blocksRlp:
    # ignore return value here
    # because good blocks maybe interleaved with
    # bad blocks
    discard importRlpBlocks(bytes, c, finalize = true)

  let head = com.db.getCanonicalHead()
  let blockHash = "0x" & head.blockHash.data.toHex
  if blockHash == cd.lastBlockHash:
    TestStatus.OK
  else:
    trace "block hash not equal",
      got=blockHash,
      number=head.number,
      expected=cd.lastBlockHash
    TestStatus.Failed

# except loopMul, all other tests are related to total difficulty
# which is not supported in ForkedChain
const unsupportedTests = [
  "lotsOfBranchesOverrideAtTheMiddle.json",
  "sideChainWithMoreTransactions.json",
  "uncleBlockAtBlock3afterBlock4.json",
  "CallContractFromNotBestBlock.json",
  "ChainAtoChainB_difficultyB.json",
  "ForkStressTest.json",
  "blockChainFrontierWithLargerTDvsHomesteadBlockchain.json",
  "blockChainFrontierWithLargerTDvsHomesteadBlockchain2.json",
  "lotsOfLeafs.json",
  "loopMul.json"
  ]

proc main() =
  const basePath = "tests/fixtures/eth_tests/BlockchainTests"
  var stat: SimStat
  let start = getTime()

  let res = loadKzgTrustedSetup()
  if res.isErr:
    echo "FATAL: ", res.error
    quit(QuitFailure)

  for fileName in walkDirRec(basePath):
    if not fileName.endsWith(".json"):
      continue

    let (_, name) = fileName.splitPath()
    if name in unsupportedTests:
      let n = json.parseFile(fileName)
      stat.skipped += n.len
      continue

    let n = json.parseFile(fileName)
    for caseName, unit in n:
      let cd = extractChainData(unit)
      let status = processChainData(cd)
      stat.inc(caseName, status)

  let elpd = getTime() - start
  print(stat, elpd, "consensus")

main()
