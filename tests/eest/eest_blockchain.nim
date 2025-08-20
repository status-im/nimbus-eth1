# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, cmdline],
  eth/common/headers_rlp,
  web3/eth_api_types,
  web3/engine_api_types,
  web3/primitives,
  web3/conversions,
  web3/execution_types,
  json_rpc/rpcclient,
  json_rpc/rpcserver,
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/beacon/beacon_engine,
  ../../execution_chain/common/common,
  ../../hive_integration/nodocker/engine/engine_client,
  ./eest_helpers,
  stew/byteutils,
  chronos,
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/common/common

proc parseBlocks*(node: JsonNode): seq[BlockDesc] =
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

proc rootExists(db: CoreDbTxRef; root: Hash32): bool =
  let state = db.getStateRoot().valueOr:
    return false
  state == root

proc runTest(env: TestEnv, unit: BlockchainUnitEnv): Future[Result[void, string]] {.async.} =
  let blocks = parseBlocks(unit.blocks)
  var lastStateRoot = unit.genesisBlockHeader.stateRoot

  for blk in blocks:
    let res = await env.chain.importBlock(blk.blk)
    if res.isOk:
      if unit.lastblockhash == blk.blk.header.computeBlockHash:
        lastStateRoot = blk.blk.header.stateRoot
      if blk.badBlock:
        return err("A bug? bad block imported")
    else:
      if not blk.badBlock:
        return err("A bug? good block rejected: " & res.error)

  (await env.chain.forkChoice(unit.lastblockhash, unit.lastblockhash)).isOkOr:
    return err("A bug? fork choice failed")

  let headHash = env.chain.latestHash
  if headHash != unit.lastblockhash:
    return err("lastestBlockHash mismatch, get: " & $headHash &
      " expect: " & $unit.lastblockhash)

  if not env.chain.txFrame(headHash).rootExists(lastStateRoot):
    return err("Last stateRoot not exists")

  ok()

proc processFile(fileName: string) =
  let
    fixture = parseFixture(fileName, BlockchainFixture)

  for unit in fixture.units:
    let header = unit.unit.genesisBlockHeader.to(Header)
    doAssert(unit.unit.genesisBlockHeader.hash == header.computeRlpHash)
    let env = prepareEnv(unit.unit, header)
    (waitFor env.runTest(unit.unit)).isOkOr:
      debugEcho "TestName: ", unit.name, "RunTest error: ", error
      quit(QuitFailure)
    env.close()

if paramCount() == 0:
  debugEcho "Usage: eest_engine vector.json"
  quit(QuitFailure)

processFile(paramStr(1))

