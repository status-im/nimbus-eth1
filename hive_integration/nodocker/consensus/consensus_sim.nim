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
  chronicles,
  ../../../nimbus/core/block_import,
  ../../../nimbus/common,
  ../sim_utils,
  ./extract_consensus_data

proc processChainData(cd: ChainData): TestStatus =
  let
    networkId = NetworkId(cd.params.config.chainId)
    com = CommonRef.new(newCoreDbRef DefaultDbMemory,
      pruneTrie = false,
      networkId,
      cd.params
    )

  com.initializeEmptyDb()

  for bytes in cd.blocksRlp:
    # ignore return value here
    # because good blocks maybe interleaved with
    # bad blocks
    discard importRlpBlock(bytes, com, "consensus_sim")

  let head = com.db.getCanonicalHead()
  let blockHash = "0x" & head.blockHash.data.toHex
  if blockHash == cd.lastBlockHash:
    TestStatus.OK
  else:
    trace "block hash not equal",
      got=blockHash,
      number=head.blockNumber,
      expected=cd.lastBlockHash
    TestStatus.Failed

proc main() =
  const basePath = "tests" / "fixtures" / "eth_tests" / "BlockchainTests"
  var stat: SimStat
  let start = getTime()

  for fileName in walkDirRec(basePath):
    if not fileName.endsWith(".json"):
      continue

    let n = json.parseFile(fileName)
    for name, unit in n:
      if "loopMul" in name:
        inc stat.skipped
        continue

      let cd = extractChainData(unit)
      let status = processChainData(cd)
      stat.inc(name, status)

  let elpd = getTime() - start
  print(stat, elpd, "consensus")

main()
