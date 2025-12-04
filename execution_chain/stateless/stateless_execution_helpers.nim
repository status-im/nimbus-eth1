# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

from ./witness_types import ExecutionWitness
from eth/rlp import read, RlpError
from eth/common/blocks import Block
from stew/byteutils import hexToSeqByte
from ./stateless_execution import statelessProcessBlock
from stint import u256
import results

export stateless_execution

func toBytes*(hexStr: string): Result[seq[byte], string] =
  try:
    ok(hexToSeqByte(hexStr))
  except ValueError as e:
    err("Error converting hex string to bytes: " & e.msg)

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
    witnessRlpBytes: openArray[byte], blkRlpBytes: openArray[byte]
): Result[void, string] =
  let
    witness = ?ExecutionWitness.decodeRlp(witnessRlpBytes)
    blk = ?Block.decodeRlp(blkRlpBytes)
  statelessProcessBlock(witness, 1.u256, blk)

proc statelessProcessBlockRlp*(
    witnessRlpStr: string, blkRlpStr: string
): Result[void, string] =
  let
    witnessRlpBytes = ?witnessRlpStr.toBytes()
    blkRlpBytes = ?blkRlpStr.toBytes()
  statelessProcessBlockRlp(witnessRlpBytes, blkRlpBytes)

proc main() = 
  echo "Input block as RLP"
  var blockIn = ""
  while true:
    try:
      let ch = stdin.readChar();
      blockIn.add(ch)
      if ch == '}':
        break
    except IOError:
      echo "Failed"
      break

  echo "Input witness as RLP"
  var witnessIn = ""
  while true:
    try:
      let ch = stdin.readChar();
      witnessIn.add(ch)
      if ch == '}':
        break
    except IOError:
      echo "Failed"
      break

  statelessProcessBlockRlp(witnessIn, blockIn).isOkOr:
    echo error

when isMainModule:
  main()
