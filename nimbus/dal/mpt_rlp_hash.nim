# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/strformat,
  ../../vendor/nim-eth/eth/common/eth_hash,
  mpt,
  utils

from ../../vendor/nimcrypto/nimcrypto/utils import fromHex

# TODO: Test
# TODO: Optimize

func rlpLegthOfLength(length: int): int =
  if length <= 55: 1
  elif length < 256: 2
  elif length < 65536: 3
  elif length < 16777216: 4
  else: 5


func rlpAppendStringLength(buffer: var seq[byte], length: int) =
  if length <= 55:
    buffer.add 128+length.byte
  elif length < 256:
    buffer.add 184
    buffer.add length.byte
  elif length < 65536:
    buffer.add 185
    buffer.add (length shr 8).byte
    buffer.add length.byte
  elif length < 16777216:
    buffer.add 186
    buffer.add (length shr 16).byte
    buffer.add (length shr 8).byte
    buffer.add length.byte
  else:
    buffer.add 187
    buffer.add (length shr 24).byte
    buffer.add (length shr 16).byte
    buffer.add (length shr 8).byte
    buffer.add length.byte


func rlpAppendListLength(buffer: var seq[byte], length: int) =
  if length <= 55:
    buffer.add 192+length.byte
  elif length < 256:
    buffer.add 248
    buffer.add length.byte
  elif length < 65536:
    buffer.add 249
    buffer.add (length shr 8).byte
    buffer.add length.byte
  elif length < 16777216:
    buffer.add 250
    buffer.add (length shr 16).byte
    buffer.add (length shr 8).byte
    buffer.add length.byte
  else:
    buffer.add 251
    buffer.add (length shr 24).byte
    buffer.add (length shr 16).byte
    buffer.add (length shr 8).byte
    buffer.add length.byte


proc encodeMptLeafAsRlp*(buffer: var seq[byte], path: array[32, byte], value: seq[byte]) =
  # A leaf is encoded as a RLP list with two items: [path, value], where the path
  # has a 1-byte prefix.
  # For leaf nodes with even-length path nibbles the prefix is 0x20.
  var encodedLen = 1 + 1 + 32 + rlpLegthOfLength(value.len) + value.len
  buffer.rlpAppendListLength encodedLen # RLP indication that a list follows with a payload of encodedLen
  buffer.add 0xa1  # RLP indication that a string follows with a payload of 33 bytes (first list item)
  buffer.add 0x20  # Path prefix (1 byte)
  buffer.add path  # Path (32 bytes)
  buffer.rlpAppendStringLength value.len # RLP indication that a string follows with a payload of value.len bytes (second list item)
  buffer.add value # Value


let emptyRlpHash = "56E81F171BCC55A6FF8345E692C0F86E5B48E01B996CADC001622FB5E363B421".fromHex

method getOrComputeHash*(leaf: MptNode): ref KeccakHash {.base.} =
  assert false

method getOrComputeHash*(leaf: MptLeaf): ref KeccakHash =
  if leaf.hash != nil:
    return leaf.hash

  var buffer: seq[byte]
  encodeMptLeafAsRlp(buffer, leaf.path.bytes, leaf.value)
  echo &"Leaf RLP: {buffer.toHex}"
  new leaf.hash
  leaf.hash[] = keccakHash(buffer)
  return leaf.hash
