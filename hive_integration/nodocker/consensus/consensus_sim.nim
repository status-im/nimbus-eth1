# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, json, strutils, times],
  eth/[common, trie/db], stew/byteutils,
  ../../../nimbus/db/db_chain,
  ../../../nimbus/[genesis, chain_config, conf_utils],
  ../sim_utils,
  ./extract_consensus_data

proc processChainData(cd: ChainData): TestStatus =
  var np: NetworkParams
  doAssert decodeNetworkParams(cd.genesis, np)

  let
    networkId = NetworkId(np.config.chainId)
    chainDB = newBaseChainDB(newMemoryDB(),
      pruneTrie = false,
      networkId,
      np
    )

  initializeEmptyDb(chainDB)
  discard importRlpBlock(cd.blocksRlp, chainDB, "consensus_sim")
  let head = chainDB.getCanonicalHead()
  let blockHash = "0x" & head.blockHash.data.toHex
  if blockHash == cd.lastBlockHash:
    TestStatus.OK
  else:
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
