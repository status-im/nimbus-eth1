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
    genesisHeader: BlockHeader
    lastBlockHash: Hash256
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
  result.lastBlockHash = Hash256(data: hexToByteArray[32](node["lastblockhash"].getStr))
  result.network = node["network"].getStr
  result.pre = node["pre"]

proc rootExists(db: CoreDbRef; root: Hash256): bool =
  let
    ctx = db.ctx
    col = ctx.newColumn(CtAccounts, root).valueOr:
      return false
  ctx.getAcc(col).isOkOr:
    return false
  true

proc executeCase(node: JsonNode): bool =
  let
    env     = parseEnv(node)
    memDB   = newCoreDbRef DefaultDbMemory
    stateDB = LedgerRef.init(memDB, EMPTY_ROOT_HASH)
    config  = getChainConfig(env.network)
    com     = CommonRef.new(memDB, config)

  setupStateDB(env.pre, stateDB)
  stateDB.persist()

  if not com.db.persistHeader(env.genesisHeader,
                              com.consensus == ConsensusType.POS):
    debugEcho "Failed to put genesis header into database"
    return false

  if com.db.getCanonicalHead().blockHash != env.genesisHeader.blockHash:
    debugEcho "Genesis block hash is database different with expected genesis block hash"
    return false

  var c = initForkedChain(com, env.genesisHeader)
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

  let head = com.db.getCanonicalHead()
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

  let res = loadKzgTrustedSetup()
  if res.isErr:
    echo "FATAL: ", res.error
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
      var testStatusIMPL: TestStatus
      let node = json.parseFile(name)
      executeFile(node, testStatusIMPL)

    executeFile("tests/fixtures/eth_tests/BlockchainTests/ValidBlocks/bcTotalDifficultyTest/sideChainWithMoreTransactions.json")
  else:
    blockchainJsonMain()
