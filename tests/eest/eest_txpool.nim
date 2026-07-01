# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# To make the isMainModule functionality work
{.define: unittest2DisableParamFiltering.}

import
  std/[json, os, strutils],
  chronos,
  unittest2,
  stew/byteutils,
  eth/common/headers_rlp,
  web3/eth_api_types,
  web3/conversions,
  ../../tools/common/types,
  ../../execution_chain/core/tx_pool,
  ../../execution_chain/core/tx_pool/tx_desc,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/common/common,
  ./eest_helpers

proc parseBlocks*(node: JsonNode): seq[BlockDesc] =
  for x in node:
    try:
      let blockRLP = hexToSeqByte(x["rlp"].getStr)
      let blk = rlp.decode(blockRLP, EthBlock)
      result.add BlockDesc(
        blk: blk,
        #bal: parseBAL(x),
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

func setWithdrawals(xp: TxPoolRef, wds: Opt[seq[Withdrawal]]) =
  if wds.isSome:
    let withdrawals = wds.value
    xp.withdrawals = withdrawals
  else:
    xp.withdrawals = @[]

func toString(x: openArray[byte]): string =
  for c in x:
    result.add char(c)

proc importTxAndAssembleBlock(xp: TxPoolRef, blk: EthBlock): Result[EthBlock, string] =
  xp.prevRandao   = blk.header.mixHash
  xp.timestamp    = blk.header.timestamp
  xp.feeRecipient = blk.header.coinbase

  if blk.header.parentBeaconBlockRoot.isSome:
    xp.parentBeaconBlockRoot = blk.header.parentBeaconBlockRoot.value

  if blk.header.slotNumber.isSome:
    xp.slotNumber = blk.header.slotNumber.value

  xp.setWithdrawals(blk.withdrawals)
  xp.com.extraData = blk.header.extraData.toString()

  for tx in blk.transactions:
    xp.addTx(tx).isOkOr:
      return err($error)

  let
    # Overrride gasLimit
    gasLimit = Opt.some(blk.header.gasLimit)
    res = ? xp.assembleBlock(someBaseFee = true, gasLimit = gasLimit)
    blockHash = res.blk.header.computeBlockHash
    expectedBlockHash = blk.header.computeBlockHash

  if blockHash != expectedBlockHash:
    return err("Assembled block hash mismatch, got: " & $blockHash &
      " expected: " & $expectedBlockHash)

  ok(res.blk)

proc runTest(env: TestEnv, unit: BlockchainUnitEnv, statelessEnabled = false): Result[void, string] =
  let
    blocks = parseBlocks(unit.blocks)
    xp = TxPoolRef.new(env.chain, flags = {
        XP_ORDERED,
        XP_SKIP_BLOB_WRAPPER_VALIDATION,
        XP_SKIP_SIZE_VALIDATION,
      }
    )

  var
    latestStateRoot = unit.genesisBlockHeader.stateRoot

  for iBlock in blocks:
    if iBlock.badBlock:
      continue

    let
      blk = ? importTxAndAssembleBlock(xp, iBlock.blk)
      res = waitFor env.chain.importBlock(blk, finalized = true)

    if res.isOk:
      latestStateRoot = blk.header.stateRoot
    else:
      return err("Good block was rejected at import: " & res.error.msg)

    xp.removeNewBlockTxs(blk)

    if xp.len != 0:
      return err("All added transactions must be consumed by assembled block")

  let headHash = env.chain.latestHash
  if headHash != unit.lastblockhash:
    return err("Latest block hash mismatch, got: " & $headHash &
      " expected: " & $unit.lastblockhash)

  if not env.chain.txFrame(headHash).rootExists(latestStateRoot):
    return err("Latest stateRoot does not exist in the database")

  ok()

proc processFile*(filePath: string, statelessEnabled = false, parallelEnabled = false, skipFiles: seq[string] = @[]) =
  let fixture = parseFixture(filePath, BlockchainFixture)
  let fileName = filePath.splitPath().tail

  for unit in fixture.units:
    if parseEnum[TestFork](unit.unit.network) < TestFork.Merge:
      # Since our txpool only support post merge block construction,
      # we only test for post merge chain too.
      continue

    let
      testName = unit.name
      testUnit = unit.unit
    test testName & " from " & filePath:
      if fileName in skipFiles:
        skip()
      else:
        let header = testUnit.genesisBlockHeader.to(Header)
        check testUnit.genesisBlockHeader.hash == header.computeRlpHash
        let env = prepareEnv(testUnit, header, rpcEnabled = false, statelessEnabled, parallelEnabled)

        let testResult = env.runTest(testUnit, statelessEnabled)
        check testResult == Result[void, string].ok()

        env.close()

when isMainModule:
  import std/cmdline

  if paramCount() == 0:
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " vector.json"
    quit(QuitFailure)

  processFile(paramStr(1), false)
