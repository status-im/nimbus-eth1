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
  eth/common/[block_access_lists_rlp, headers_rlp],
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
  ../../execution_chain/stateless/stateless_execution,
  ../../execution_chain/stateless/stateless_guest,
  ../../execution_chain/stateless/stateless_host,
  ../../hive_integration/engine_client,
  ./eest_helpers,
  ./bal_parser

from ../../execution_chain/rpc/debug import getExecutionWitness

proc fromJson(T: type ExecutionWitness, n: JsonNode): ExecutionWitness =
  var res: ExecutionWitness
  for item in n["state"]:
    discard res.state.add(
      ByteList[MAX_BYTES_PER_WITNESS_NODE].init(hexToSeqByte(item.getStr))
    )
  for item in n["codes"]:
    discard res.codes.add(ByteList[MAX_BYTES_PER_CODE].init(hexToSeqByte(item.getStr)))
  if "headers" in n:
    for item in n["headers"]:
      discard
        res.headers.add(ByteList[MAX_BYTES_PER_HEADER].init(hexToSeqByte(item.getStr)))
  res

proc parseWitness(node: JsonNode): Opt[ExecutionWitness] =
  if "executionWitness" in node:
    Opt.some(ExecutionWitness.fromJson(node["executionWitness"]))
  else:
    Opt.none(ExecutionWitness)

proc parseBAL(node: JsonNode): Opt[BlockAccessListRef] =
  const deepValidationExceptions =
    ["INVALID_BAL_MISSING_ACCOUNT", "INVALID_BLOCK_ACCESS_LIST"]

  func doNotParseBAL(x: string): bool =
    for y in deepValidationExceptions:
      if y in x:
        return true
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
        statelessInputBytes:
          if "statelessInputBytes" in x:
            Opt.some(hexToSeqByte(x["statelessInputBytes"].getStr))
          else:
            Opt.none(seq[byte]),
        statelessOutputBytes:
          if "statelessOutputBytes" in x:
            Opt.some(hexToSeqByte(x["statelessOutputBytes"].getStr))
          else:
            Opt.none(seq[byte]),
      )
    except RlpError:
      # invalid rlp will not participate in block validation
      # e.g. invalid rlp received from network
      discard

proc rootExists(db: CoreDbTxRef, root: Hash32): bool =
  let state = db.getStateRoot().valueOr:
    return false
  state == root

proc shortLog(witness: ExecutionWitness): string =
  var res = "ExecutionWitness:\n"
  res.add "State:\n"
  for node in witness.state:
    res.add node.asSeq().to0xHex() & "\n"
  res.add "Codes:\n"
  for code in witness.codes:
    res.add code.asSeq().to0xHex() & "\n"
  res.add "Headers:\n"
  for header in witness.headers:
    res.add header.asSeq().to0xHex() & "\n"
  res

proc compare(
    generated, expected: ExecutionWitness, strict = false
): Result[void, string] =
  ## Compare witness state, codes and headers.
  ## When strict is true the witnesses must be identical.
  ## When strict is false, allow generated to be a subset of expected.
  ## This is because some test vectors include extra unused state nodes,
  ## code and headers in the witness to test that stateless execution
  ## still works. Same counts for the lexicographical order.

  if strict:
    if generated != expected:
      return err(
        "Witness mismatch, got: " & $generated.shortLog & " expected: " &
          $expected.shortLog
      )
  else:
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

proc runTest(
    env: TestEnv, unit: BlockchainUnitEnv, statelessEnabled = false
): Future[Result[void, string]] {.async.} =
  let blocks = parseBlocks(unit.blocks)
  var latestStateRoot = unit.genesisBlockHeader.stateRoot

  for blk in blocks:
    # Stateful test
    let res = await env.chain.importBlock(blk.blk, blk.bal, finalized = true)
    if res.isOk:
      if unit.lastblockhash == blk.blk.header.computeBlockHash:
        latestStateRoot = blk.blk.header.stateRoot
      if blk.badBlock:
        return err("Bad block got imported succesfully")
    else:
      if not blk.badBlock:
        return err("Good block was rejected at import: " & res.error.msg)

    if not statelessEnabled:
      continue

    # Stateless test

    var expectedSuccessful = false

    # Run the full stateless guest pipeline with the test-vector bytes
    # when both input and output are provided.
    if blk.statelessInputBytes.isSome and blk.statelessOutputBytes.isSome:
      let
        expectedOutput =
          try:
            SSZ.decode(blk.statelessOutputBytes.get(), StatelessValidationResult)
          except SerializationError as e:
            return err("Failed to decode expected stateless guest output: " & e.msg)

        outputBytes = run_stateless_guest(blk.statelessInputBytes.value())
        output =
          try:
            SSZ.decode(outputBytes, StatelessValidationResult)
          except SerializationError as e:
            return err("Failed to decode stateless guest output: " & e.msg)

      expectedSuccessful = expectedOutput.successful_validation

      # if output != expectedOutput:
      # TODO: The `new_payload_request_root` comparison is temporarily skipped.
      # The stateless fixtures are generated from execution-specs, which is no
      # longer up to date regarding `gloas.ExecutionPayload` usage of progressive
      # lists (EIP-7688).
      if output.successful_validation != expectedOutput.successful_validation or
          output.chain_config != expectedOutput.chain_config:
        return err(
          "Stateless guest: validation result mismatch, got: " & $output & " expected: " &
            $expectedOutput
        )

      # Verify that the SSZ input witness matches the JSON witness field.
      # This rather validates the test vector itself, not our implementation.
      if expectedSuccessful and blk.witness.isSome:
        let statelessInput = deserialize_stateless_input(blk.statelessInputBytes.get()).valueOr:
          return err("Failed to deserialize StatelessInput: " & error)
        ?compare(statelessInput.witness, blk.witness.get(), strict = true)

    # Run the full host + guest stateless pipeline with data generated by the
    # full node during import: build the stateless input from the block, the
    # generated witness, block access list and execution requests, serialize
    # it, run the guest and verify the output. The data is only stored for
    # successfully imported blocks, so skip if import failed. Note that failed
    # import for not bad block fails early.
    if res.isOk:
      let
        blockHash = blk.blk.header.computeRlpHash
        witnessWithKeys = env.chain.getExecutionWitness(blockHash).valueOr:
          return err("Execution witness was not found in the database")
        generatedWitness = witnessWithKeys.toExecutionWitness()

      # Only run the host + guest pipeline when the test vector carries a
      # stateless input that is expected to validate: the fixtures generator
      # stores no input for blocks it cannot represent in the current input
      # schema (EIP-8282 builder requests) and negative vectors deliberately
      # tamper with or corrupt the input, while it is also the source of the
      # execution requests below.
      if expectedSuccessful and
          env.chain.com.isAmsterdamOrLater(blk.blk.header.timestamp):
        let
          fixtureInput = deserialize_stateless_input(blk.statelessInputBytes.get()).valueOr:
            return err("Failed to deserialize StatelessInput: " & error)
          bal = env.chain.getBlockAccessList(blockHash).valueOr:
            return err("Block access list was not found in the database")
          # Note: We borrow the executionRequests from the test vector.
          # Execution requests are derived from execution output, which is no
          # longer available after import. An actualy production setup would
          # receive them prepped in the engine API newPayload call instead.
          input = ?build_stateless_input(
            blk.blk,
            generatedWitness,
            fixtureInput.new_payload_request.executionRequests,
            encode(bal),
            env.chain.com.chainId.truncate(uint64),
          )
          outputBytes = run_stateless_guest(serialize_stateless_input(input))
          output = ?deserialize_stateless_output(outputBytes)

        ?verify_new_payload_request_root(input, output)
        if not output.successful_validation:
          return err("Stateless guest failed to validate the host-built input")

        # Compare the host-built input and the guest output against the test
        # vector.
        #
        # TODO:
        # The full input + output comparison is disabled: the stateless input
        # of the blockchain_test_from_state_test vectors is generated by the
        # EELS t8n from a block variant with an empty extraData (hardcoded,
        # the t8n env format carries no extraData), while the emitted fixture
        # block has extraData 0x00 (test framework default). The two differ in
        # exactly extra_data and the derived block_hash. All other payload fields
        # were verified equal and hashing the fixture header with an empty extraData
        # reproduces the vector input's block_hash. To be fixed and re-enabled.
        #
        # if input.new_payload_request != fixtureInput.new_payload_request:
        #   return err("Host-built new payload request does not match the test vector")
        if input.chain_config != fixtureInput.chain_config:
          return err("Host-built chain config does not match the test vector")
        if input.public_keys != fixtureInput.public_keys:
          return err("Host-built public keys do not match the test vector")
        # The generated witness must be a subset of the test vector witness,
        # which may deliberately contain extra nodes and differ in order.
        ?compare(generatedWitness, fixtureInput.witness)

        # TODO:
        #Disabled for the same reason as the new payload request comparison
        # above; the validation flag and the config echo remain comparable.
        let expectedOutput =
          ?deserialize_stateless_output(blk.statelessOutputBytes.get())
        # if output != expectedOutput:
        #   return err("Guest output for the host-built input does not match the test vector")
        if output.successful_validation != expectedOutput.successful_validation:
          return err("Guest validation result does not match the test vector")
        if output.chain_config != expectedOutput.chain_config:
          return err("Guest chain config echo does not match the test vector")
      else:
        # Pre-Amsterdam blocks (guest only supports Amsterdam) and blocks without
        # a stateless input expected to validate: run the generated witness through
        # statelessProcessBlock directly.
        ?generatedWitness.statelessProcessBlock(env.chain.com, blk.blk)

  (await env.chain.forkChoice(unit.lastblockhash, unit.lastblockhash)).isOkOr:
    return err("Fork choice failed")

  let headHash = env.chain.latestHash
  if headHash != unit.lastblockhash:
    return err(
      "Latest block hash mismatch, got: " & $headHash & " expected: " &
        $unit.lastblockhash
    )

  if not env.chain.txFrame(headHash).rootExists(latestStateRoot):
    return err("Latest stateRoot does not exist in the database")

  ok()

proc processFile*(
    filePath: string,
    statelessEnabled = false,
    parallelEnabled = false,
    skipFiles: seq[string] = @[],
) =
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
        let env = prepareEnv(
          testUnit, header, rpcEnabled = false, statelessEnabled, parallelEnabled
        )

        let testResult = waitFor env.runTest(testUnit, statelessEnabled)
        check testResult == Result[void, string].ok()

        env.close()

when isMainModule:
  import std/cmdline

  if paramCount() == 0:
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " vector.json"
    quit(QuitFailure)

  processFile(paramStr(1), statelessEnabled = true)
