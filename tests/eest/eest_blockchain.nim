# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# To make the isMainModule functionality work
{.define: unittest2DisableParamFiltering.}

import
  std/[json, os],
  unittest2,
  chronos,
  stew/byteutils,
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
  ../../execution_chain/stateless/witness_types,
  ../../execution_chain/stateless/stateless_types,
  ../../execution_chain/stateless/stateless_execution,
  ../../hive_integration/engine_client,
  ./eest_helpers,
  ./bal_parser

from ../../execution_chain/rpc/debug import getExecutionWitness

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

proc parseWitness(node: JsonNode): Opt[ExecutionWitness] =
  if "executionWitness" in node:
    Opt.some(ExecutionWitness.fromJson(node["executionWitness"]))
  else:
    Opt.none(ExecutionWitness)

proc parseStatelessOutput(node: JsonNode): Opt[StatelessValidationResult] =
  if "statelessOutputBytes" in node:
    let sszBytes = hexToSeqByte(node["statelessOutputBytes"].getStr)
    try:
      Opt.some(SSZ.decode(sszBytes, StatelessValidationResult))
    except SerializationError as e:
      raiseAssert("Failed to deserialize StatelessValidationResult: " & e.msg)
  else:
    Opt.none(StatelessValidationResult)

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

proc parseBlocks*(node: JsonNode): seq[BlockDesc] =
  for x in node:
    try:
      let blockRLP = hexToSeqByte(x["rlp"].getStr)
      let blk = rlp.decode(blockRLP, EthBlock)
      result.add BlockDesc(
        blk: blk,
        bal: parseBAL(x),
        badBlock: "expectException" in x,
        witness: parseWitness(x),
        statelessValidationResult: parseStatelessOutput(x)
      )
    except RlpError:
      # invalid rlp will not participate in block validation
      # e.g. invalid rlp received from network
      discard

proc rootExists(db: CoreDbTxRef; root: Hash32): bool =
  let state = db.getStateRoot().valueOr:
    return false
  state == root

proc shortLog(witness: ExecutionWitness): string =
  var res = "ExecutionWitness:\n"
  res.add "State:\n"
  for stateNode in witness.state:
    res.add stateNode.to0xHex() & "\n"
  res.add "Codes:\n"
  for codeNode in witness.codes:
    res.add codeNode.to0xHex() & "\n"
  res.add "Headers:\n"
  for headerNode in witness.headers:
    res.add headerNode.to0xHex() & "\n"
  res

proc compare(
    generated, expected: ExecutionWitness, strict = false
): Result[void, string] =
  ## Compare witness state, nodes and headers, not comparing keys as these
  ## are not included in the test vectors.
  ## When strict is false, allow generated witness state, codes and headers to
  ## be a subset of expected. This is because some test vectors include extra
  ## unused state nodes, code and headers in the witness to test that stateless
  ## execution still works. Same counts for the lexicographical order.

  if strict:
    # when strict enabled, also compare state and codes to be identical
    if generated.state != expected.state:
      return err(
        "Witness state mismatch, got: " & $generated.shortLog & " expected: " &
          $expected.shortLog
      )
    if generated.codes != expected.codes:
      return err(
        "Witness codes mismatch, got: " & $generated.shortLog & " expected: " &
          $expected.shortLog
      )
    if generated.headers != expected.headers:
      return err(
        "Witness headers mismatch, got: " & $generated.shortLog & " expected: " &
          $expected.shortLog
      )
  else:
    # else allow them just to be a subset of expected
    for node in generated.state:
      if node notin expected.state:
        return err(
          "Witness state node missing from expected, got: " & $generated.shortLog &
            " expected: " & $expected.shortLog
        )

    for code in generated.codes:
      if code notin expected.codes:
        return err(
          "Witness code missing from expected, got: " & $generated.shortLog &
            " expected: " & $expected.shortLog
        )

    for header in generated.headers:
      if header notin expected.headers:
        return err(
          "Witness header missing from expected, got: " & $generated.shortLog &
            " expected: " & $expected.shortLog
        )

  ok()

proc runTest(env: TestEnv, unit: BlockchainUnitEnv, statelessEnabled = false): Future[Result[void, string]] {.async.} =
  let blocks = parseBlocks(unit.blocks)
  var latestStateRoot = unit.genesisBlockHeader.stateRoot

  for blk in blocks:
    let res = await env.chain.importBlock(blk.blk, blk.bal, finalized = true)
    if res.isOk:
      if unit.lastblockhash == blk.blk.header.computeBlockHash:
        latestStateRoot = blk.blk.header.stateRoot
      if blk.badBlock:
        return err("Bad block got imported succesfully")
      else:
        if statelessEnabled:
          # Get witness that should have been generated when importing the block
          var witness = env.chain.getExecutionWitness(blk.blk.header.computeRlpHash).valueOr:
            return err("Execution witness was not found in the database")

          # process block stateless with generated witness
          ?witness.statelessProcessBlock(env.chain.com, blk.blk, verifyState = true)

          let successful_validation =
            if blk.statelessValidationResult.isSome():
              blk.statelessValidationResult.get().successful_validation
            else:
              true

          if blk.witness.isSome() and successful_validation:
            # If block witness in test vector and validation is successful,
            # process block stateless with test vector witness
            let expectedWitness = blk.witness.value()
            ?expectedWitness.statelessProcessBlock(env.chain.com, blk.blk)

            # compare both witnesses
            ?compare(witness, expectedWitness)
    else:
      if not blk.badBlock:
        return err("Good block was rejected at import: " & res.error)

  (await env.chain.forkChoice(unit.lastblockhash, unit.lastblockhash)).isOkOr:
    return err("Fork choice failed")

  let headHash = env.chain.latestHash
  if headHash != unit.lastblockhash:
    return err("Latest block hash mismatch, got: " & $headHash &
      " expected: " & $unit.lastblockhash)

  if not env.chain.txFrame(headHash).rootExists(latestStateRoot):
    return err("Latest stateRoot does not exist in the database")

  ok()

proc processFile*(filePath: string, statelessEnabled = false, skipFiles: seq[string] = @[]) =
  let fixture = parseFixture(filePath, BlockchainFixture)
  let fileName = filePath.splitPath().tail

  for unit in fixture.units:
    let
      testName = unit.name
      testUnit = unit.unit
    test testName & " from " & filePath:
      if fileName in skipFiles:
        skip()
      else:
        let header = testUnit.genesisBlockHeader.to(Header)
        check testUnit.genesisBlockHeader.hash == header.computeRlpHash
        let env = prepareEnv(testUnit, header, rpcEnabled = false, statelessEnabled)

        let testResult = waitFor env.runTest(testUnit, statelessEnabled)
        check testResult == Result[void, string].ok()

        env.close()

when isMainModule:
  import std/cmdline

  if paramCount() == 0:
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " vector.json"
    quit(QuitFailure)

  processFile(paramStr(1), true)
