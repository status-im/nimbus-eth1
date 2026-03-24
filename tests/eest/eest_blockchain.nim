# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, algorithm],
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
  ../../hive_integration/engine_client,
  ../../execution_chain/stateless/witness_types,
  ./eest_helpers,
  ./bal_parser,
  stew/byteutils,
  chronos

from ../../execution_chain/rpc/debug import getExecutionWitness

proc parseBAL(node: JsonNode): Opt[BlockAccessListRef] =
  const
    deepValidationExceptions = [
      "INVALID_BAL_MISSING_ACCOUNT",
      "INVALID_BLOCK_ACCESS_LIST"
    ]

  func doNotParseBAL(x: string): bool =
    for y in deepValidationExceptions:
      if y in x: return true
    false

  if "expectException" in node:
    if doNotParseBAL(node["expectException"].getStr):
      return Opt.none(BlockAccessListRef)

  if "rlp_decoded" in node:
    # Only need shallow validation
    let inner = node["rlp_decoded"]
    if "blockAccessList" in inner:
      let bal = new(BlockAccessListRef)
      bal[] = balFromJson(inner["blockAccessList"])
      return Opt.some(bal)

proc hexListToSeqByteList(n: JsonNode, field: string): seq[seq[byte]] =
  var res: seq[seq[byte]]
  for item in n[field]:
    res.add hexToSeqByte(item.getStr)

  res

proc fromJson(T: type ExecutionWitness, n: JsonNode): ExecutionWitness =
  ExecutionWitness(
    state: hexListToSeqByteList(n, "state"),
    codes: hexListToSeqByteList(n, "codes"),
    keys: if "keys" in n: hexListToSeqByteList(n, "keys") else: @[],
    headers: hexListToSeqByteList(n, "headers")
  )

proc parseWitness*(node: JsonNode): Opt[ExecutionWitness] =
  if "executionWitness" in node:
    Opt.some(ExecutionWitness.fromJson(node["executionWitness"]))
  else:
    Opt.none(ExecutionWitness)

proc parseBlocks*(node: JsonNode): seq[BlockDesc] =
  for x in node:
    try:
      let blockRLP = hexToSeqByte(x["rlp"].getStr)
      let blk = rlp.decode(blockRLP, EthBlock)
      result.add BlockDesc(
        blk: blk,
        badBlock: "expectException" in x,
        bal: parseBAL(x),
        witness: parseWitness(x)
      )
    except RlpError:
      # invalid rlp will not participate in block validation
      # e.g. invalid rlp received from network
      discard

proc rootExists(db: CoreDbTxRef; root: Hash32): bool =
  let state = db.getStateRoot().valueOr:
    return false
  state == root

proc runTest(env: TestEnv, unit: BlockchainUnitEnv, statelessEnabled = false): Future[Result[void, string]] {.async.} =
  let blocks = parseBlocks(unit.blocks)
  var lastStateRoot = unit.genesisBlockHeader.stateRoot

  for blk in blocks:
    let res = await env.chain.importBlock(blk.blk, blk.bal, finalized = true)
    if res.isOk:
      if unit.lastblockhash == blk.blk.header.computeBlockHash:
        lastStateRoot = blk.blk.header.stateRoot
      if blk.badBlock:
        return err("A bug? bad block imported")
      else:
        if statelessEnabled and blk.witness.isSome():
          # Get witness that should have been generated when importing the block
          var witness = env.chain.getExecutionWitness(blk.blk.header.computeRlpHash).valueOr:
            return err("Execution witness not found")

          # Compare witness with test vector witness
          # Note: Sorting seq of state and codes as is done in execution-specs:
          # - https://github.com/ethereum/execution-specs/blob/33aa038697162a3ba0aedbadf177c4c59ee5b007/src/ethereum/forks/amsterdam/stateless_host_exec_witness.py#L230
          # - https://github.com/ethereum/execution-specs/blob/33aa038697162a3ba0aedbadf177c4c59ee5b007/src/ethereum/forks/amsterdam/stateless_host_exec_witness.py#L268
          witness.state.sort()
          witness.codes.sort()
          let expectedWitness = blk.witness.value()
          if witness.state != expectedWitness.state:
            return err("Witness state mismatch")
          if witness.codes != expectedWitness.codes:
            return err("Witness codes mismatch")
          if witness.headers != expectedWitness.headers:
            return err("Witness headers mismatch")
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

proc processFile*(fileName: string, statelessEnabled = false): bool =
  let
    fixture = parseFixture(fileName, BlockchainFixture)

  var testPass = true
  for unit in fixture.units:
    let header = unit.unit.genesisBlockHeader.to(Header)
    doAssert(unit.unit.genesisBlockHeader.hash == header.computeRlpHash)
    let env = prepareEnv(unit.unit, header, rpcEnabled = false, statelessEnabled)
    (waitFor env.runTest(unit.unit, statelessEnabled)).isOkOr:
      echo "TestName: ", unit.name, " RunTest error: ", error, "\n"
      testPass = false
    env.close()

  return testPass

when isMainModule:
  import
    os,
    unittest2

  if paramCount() == 0:
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " vector.json"
    quit(QuitFailure)

  check processFile(paramStr(1))
