# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, parseopt, strformat, json],
  eth/[common, trie/db], stew/byteutils,
  ../../../nimbus/db/db_chain,
  ../../../nimbus/[genesis, config, conf_utils],
  ../sim_utils

proc processNode(genesisFile, chainFile,
                 lastBlockHash: string, testStatusIMPL: var TestStatus) =
  var msg: string
  var opt = initOptParser("--customnetwork:" & genesisFile)
  let res = processArguments(msg, opt)
  if res != Success:
    echo msg
    quit(QuitFailure)

  let
    conf = getConfiguration()
    chainDB = newBaseChainDB(newMemoryDb(),
      pruneTrie = false,
      conf.net.networkId
    )

  initializeEmptyDb(chainDB)
  discard importRlpBlock(chainFile, chainDB, forceCanonicalParent = true)
  let head = chainDB.getCanonicalHead()
  let blockHash = "0x" & head.blockHash.data.toHex
  check blockHash == lastBlockHash

proc main() =
  let caseFolder = if paramCount() == 0:
                     "consensus_data"
                   else:
                     paramStr(1)

  if not caseFolder.dirExists:
    # Handy early error message and stop directive
    let progname = getAppFilename().extractFilename
    quit(&"*** {progname}: Not a case folder: {caseFolder}")

  runTest("Consensus", caseFolder):
    # Variable `fileName` is injected by `runTest()`
    let node = parseFile(fileName)
    processNode(fileName, node["chainfile"].getStr,
      node["lastblockhash"].getStr, testStatusIMPL)

main()
