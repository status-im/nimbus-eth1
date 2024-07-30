# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/state-network.md#content-keys-and-content-ids

{.push raises: [].}

import
  nimcrypto/hash,
  results,
  stint,
  eth/common/eth_types,
  ssz_serialization,
  ../../../common/common_types

export ssz_serialization, common_types, hash, results

const
  MAX_PACKED_NIBBLES_LEN = 33
  MAX_UNPACKED_NIBBLES_LEN = 64

type Nibbles* = List[byte, MAX_PACKED_NIBBLES_LEN]
type UnpackedNibbles* = seq[byte]

func init*(T: type Nibbles, packed: openArray[byte], isEven: bool): T =
  doAssert(packed.len() <= MAX_PACKED_NIBBLES_LEN)

  var output = newSeqOfCap[byte](packed.len() + 1)
  if isEven:
    output.add(0x00)
  else:
    doAssert(packed.len() > 0)
    # set the first nibble to 1 and copy the second nibble from the input
    output.add((packed[0] and 0x0F) or 0x10)

  let startIdx = if isEven: 0 else: 1
  for i in startIdx ..< packed.len():
    output.add(packed[i])

  Nibbles(output)

func empty*(T: type Nibbles): T =
  Nibbles.init(@[], true)

func encode*(nibbles: Nibbles): seq[byte] =
  SSZ.encode(nibbles)

func decode*(T: type Nibbles, bytes: openArray[byte]): Result[T, string] =
  decodeSsz(bytes, T)

func packNibbles*(unpacked: openArray[byte]): Nibbles =
  doAssert(
    unpacked.len() <= MAX_UNPACKED_NIBBLES_LEN, "Can't pack more than 64 nibbles"
  )

  if unpacked.len() == 0:
    return Nibbles(@[byte(0x00)])

  let isEvenLength = unpacked.len() mod 2 == 0

  var
    output = newSeqOfCap[byte](unpacked.len() div 2 + 1)
    highNibble = isEvenLength
    currentByte: byte = 0

  if isEvenLength:
    output.add(0x00)
  else:
    currentByte = 0x10

  for i, nibble in unpacked:
    if highNibble:
      currentByte = nibble shl 4
    else:
      output.add(currentByte or nibble)
      currentByte = 0
    highNibble = not highNibble

  Nibbles(output)

func unpackNibbles*(packed: Nibbles): UnpackedNibbles =
  doAssert(packed.len() <= MAX_PACKED_NIBBLES_LEN, "Packed nibbles length is too long")

  var output = newSeqOfCap[byte](packed.len() * 2)

  for i, pair in packed:
    if i == 0 and pair == 0x00:
      continue

    let
      first = (pair and 0xF0) shr 4
      second = pair and 0x0F

    if i == 0 and first == 0x01:
      output.add(second)
    else:
      output.add(first)
      output.add(second)

  ensureMove(output)

func len(packed: Nibbles): int =
  let lenExclPrefix = (packed.len() - 1) * 2

  if packed[0] == 0x00: # is even length
    lenExclPrefix
  else:
    lenExclPrefix + 1

func dropN*(unpacked: UnpackedNibbles, num: int): UnpackedNibbles =
  var nibbles = unpacked
  nibbles.setLen(nibbles.len() - num)
  ensureMove(nibbles)
