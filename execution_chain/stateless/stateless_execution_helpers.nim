# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  eth/common/blocks_rlp,
  web3/[eth_api_types, conversions],
  stew/io2,
  ./stateless_execution

from ../../hive_integration/engine_client import toBlockHeader, toTransactions

export stateless_execution

ExecutionWitness.useDefaultSerializationIn JrpcConv

proc statelessProcessBlockRlp*(
    witnessRlpBytes: openArray[byte], com: CommonRef, blkRlpBytes: openArray[byte]
): Result[void, string] =
  let
    witness = ?ExecutionWitness.decode(witnessRlpBytes)
    blk =
      try:
        rlp.decode(blkRlpBytes, Block)
      except RlpError as e:
        return err(e.msg)
  statelessProcessBlock(witness, com, blk)

func toBlock(blockObject: BlockObject): Block =
  Block.init(
    blockObject.toBlockHeader(),
    BlockBody(
      transactions: blockObject.transactions.toTransactions(),
      withdrawals: blockObject.withdrawals,
    ),
  )

proc statelessProcessBlockJson*(
    witnessJson: string, com: CommonRef, blkJson: string
): Result[void, string] =
  try:
    let
      witness = JrpcConv.decode(witnessJson, ExecutionWitness)
      blk = JrpcConv.decode(blkJson, BlockObject).toBlock()
    statelessProcessBlock(witness, com, blk)
  except SerializationError as e:
    return err(e.msg)

proc statelessProcessBlockJsonFiles*(
    witnessJsonFilePath: string, com: CommonRef, blockJsonFilePath: string
): Result[void, string] =
  let
    witnessFileStr = io2.readAllChars(witnessJsonFilePath).valueOr:
      return err("Reading witness json file failed")
    blkFileStr = io2.readAllChars(blockJsonFilePath).valueOr:
      return err("Reading block json file failed")
  statelessProcessBlockJson(witnessFileStr, com, blkFileStr)
