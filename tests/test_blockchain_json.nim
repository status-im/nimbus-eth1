# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/json,
  unittest2,
  stew/byteutils,
  ./test_helpers,
  ./test_allowed_to_fail,
  ../nimbus/db/ledger,
  ../nimbus/core/chain/forked_chain,
  ../tools/common/helpers as chp,
  ../tools/evmstate/helpers,
  ../nimbus/common/common,
  ../nimbus/core/eip4844

const
  debugMode = false

type
  BlockDesc = object
    blk: EthBlock
    badBlock: bool

  TestEnv = object
    blocks: seq[BlockDesc]
    genesisHeader: Header
    lastBlockHash: Hash32
    network: string
    pre: JsonNode

proc parseBlocks(node: JsonNode): seq[BlockDesc] =
  for x in node:
    try:
      let blockRLP = hexToSeqByte(x["rlp"].getStr)
      let blk = rlp.decode(blockRLP, EthBlock)
      result.add BlockDesc(
        blk: blk,
        badBlock: "expectException" in x,
      )
    except RlpError:
      # invalid rlp will not participate in block validation
      # e.g. invalid rlp received from network
      discard

proc parseEnv(node: JsonNode): TestEnv =
  result.blocks = parseBlocks(node["blocks"])
  let genesisRLP = hexToSeqByte(node["genesisRLP"].getStr)
  result.genesisHeader = rlp.decode(genesisRLP, EthBlock).header
  result.lastBlockHash = Hash32(hexToByteArray[32](node["lastblockhash"].getStr))
  result.network = node["network"].getStr
  result.pre = node["pre"]

proc rootExists(db: CoreDbRef; root: Hash32): bool =
  let state = db.ctx.getAccounts().getStateRoot().valueOr:
    return false
  state == root

proc executeCase(node: JsonNode): bool =
  let
    env     = parseEnv(node)
    memDB   = newCoreDbRef DefaultDbMemory
    stateDB = LedgerRef.init(memDB)
    config  = getChainConfig(env.network)
    com     = CommonRef.new(memDB, config)

  setupStateDB(env.pre, stateDB)
  stateDB.persist()

  com.db.persistHeader(env.genesisHeader,
                       com.proofOfStake(env.genesisHeader)).isOkOr:
    debugEcho "Failed to put genesis header into database: ", error
    return false

  let chead = com.db.getCanonicalHead().expect("canonicalHead exists")
  if chead.blockHash != env.genesisHeader.blockHash:
    debugEcho "Genesis block hash in database is different with expected genesis block hash"
    return false

  var c = newForkedChain(com, env.genesisHeader)
  var lastStateRoot = env.genesisHeader.stateRoot
  for blk in env.blocks:
    let res = c.importBlock(blk.blk)
    if res.isOk:
      if env.lastBlockHash == blk.blk.header.blockHash:
        lastStateRoot = blk.blk.header.stateRoot
      if blk.badBlock:
        debugEcho "A bug? bad block imported"
        return false
    else:
      if not blk.badBlock:
        debugEcho "A bug? good block rejected: ", res.error
        return false

  c.forkChoice(env.lastBlockHash, env.lastBlockHash).isOkOr:
    debugEcho error
    return false

  let head = com.db.getCanonicalHead().expect("canonicalHead exists")
  let headHash = head.blockHash
  if headHash != env.lastBlockHash:
    debugEcho "lastestBlockHash mismatch, get: ", headHash,
      " expect: ", env.lastBlockHash
    return false

  if not memDB.rootExists(lastStateRoot):
    debugEcho "Last stateRoot not exists"
    return false

  true

proc executeFile(node: JsonNode, testStatusIMPL: var TestStatus) =
  for name, bctCase in node:
    when debugMode:
      debugEcho "TEST NAME: ", name
    check executeCase(bctCase)

proc blockchainJsonMain*() =
  const
    legacyFolder = "eth_tests/LegacyTests/Constantinople/BlockchainTests"
    newFolder = "eth_tests/BlockchainTests"

  loadKzgTrustedSetup().isOkOr:
    echo "FATAL: ", error
    quit(QuitFailure)

  if false:
    suite "block chain json tests":
      jsonTest(legacyFolder, "BlockchainTests", executeFile, skipBCTests)
  else:
    suite "new block chain json tests":
      jsonTest(newFolder, "newBlockchainTests", executeFile, skipNewBCTests)

when isMainModule:
  when debugMode:
    proc executeFile(name: string) =
      loadKzgTrustedSetup().isOkOr:
        echo "FATAL: ", error
        quit(QuitFailure)

      var testStatusIMPL: TestStatus
      let node = json.parseFile(name)
      executeFile(node, testStatusIMPL)
      if testStatusIMPL == FAILED:
        quit(QuitFailure)

    executeFile("tests/fixtures/eth_tests/BlockchainTests/GeneralStateTests/stTransactionTest/ValueOverflowParis.json")
  else:
    blockchainJsonMain()
