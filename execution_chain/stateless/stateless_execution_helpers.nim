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
  stew/[io2, byteutils],
  ./stateless_execution

from ../../hive_integration/engine_client import toBlockHeader, toTransactions

export stateless_execution

ExecutionWitness.useDefaultSerializationIn JrpcConv

proc readFileToStr*(filePath: string): Result[string, string] =
  let fileStr = io2.readAllChars(filePath).valueOr:
    return err("Error reading file: " & filePath)
  ok(fileStr)

func toBytes*(hexStr: string): Result[seq[byte], string] =
  try:
    ok(hexToSeqByte(hexStr))
  except ValueError as e:
    err("Error converting hex string to bytes: " & e.msg)

func decodeJson*(T: type ExecutionWitness, jsonStr: string): Result[T, string] =
  try:
    ok(JrpcConv.decode(jsonStr, T))
  except SerializationError as e:
    err("Error decoding json string: " & e.msg)

func decodeJson*(T: type BlockObject, jsonStr: string): Result[T, string] =
  try:
    ok(JrpcConv.decode(jsonStr, T))
  except SerializationError as e:
    err("Error decoding json string: " & e.msg)

func toBlock*(blockObject: BlockObject): Block =
  Block.init(
    blockObject.toBlockHeader(),
    BlockBody(
      transactions: blockObject.transactions.toTransactions(),
      withdrawals: blockObject.withdrawals,
    ),
  )

func decodeRlp*(
    T: type ExecutionWitness, rlpBytes: openArray[byte]
): Result[T, string] =
  try:
    ok(rlp.decode(rlpBytes, T))
  except RlpError as e:
    err("Error decoding rlp bytes: " & e.msg)

func decodeRlp*(T: type Block, rlpBytes: openArray[byte]): Result[T, string] =
  try:
    ok(rlp.decode(rlpBytes, T))
  except RlpError as e:
    err("Error decoding rlp bytes: " & e.msg)

proc statelessProcessBlockRlp*(
    witnessRlpBytes: openArray[byte], com: CommonRef, blkRlpBytes: openArray[byte]
): Result[void, string] =
  let
    witness = ?ExecutionWitness.decodeRlp(witnessRlpBytes)
    blk = ?Block.decodeRlp(blkRlpBytes)
  statelessProcessBlock(witness, com, blk)

proc statelessProcessBlockRlp*(
    witnessRlpStr: string, com: CommonRef, blkRlpStr: string
): Result[void, string] =
  let
    witnessRlpBytes = ?witnessRlpStr.toBytes()
    blkRlpBytes = ?blkRlpStr.toBytes()
  statelessProcessBlockRlp(witnessRlpBytes, com, blkRlpBytes)

proc statelessProcessBlockJson*(
    witnessJson: string, com: CommonRef, blkJson: string
): Result[void, string] =
  let
    witness = ?ExecutionWitness.decodeJson(witnessJson)
    blkObject = ?BlockObject.decodeJson(blkJson)
  statelessProcessBlock(witness, com, blkObject.toBlock())

proc statelessProcessBlockJsonFiles*(
    witnessJsonFilePath: string, com: CommonRef, blockJsonFilePath: string
): Result[void, string] =
  let
    witnessJson = ?readFileToStr(witnessJsonFilePath)
    blkJson = ?readFileToStr(blockJsonFilePath)
  statelessProcessBlockJson(witnessJson, com, blkJson)
