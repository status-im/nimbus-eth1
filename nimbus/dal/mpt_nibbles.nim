#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.


## This module provides two memory-efficient data structures for working with
## 'nibbles'. A nibble is a 4-bit value. To save on RAM, we store two nibbles
## per byte. We provide methods for working with logical nibbles instead of
## bytes.


type
  Nibbles64* = object
    ## Holds 64 nibbles in a 32-bytes array. Nibbles are accessed and assigned
    ## using the indexing operator (`[]`).
    bytes*: array[32, byte]

  Nibbles* = object
    ## Holds up to 62 nibbles (the maximum that an extension node in a MPT tree
    ## can have), in a fixed 32 bytes array. The number of nibbles held is
    ## stored in the last byte of the array. Nibbles are accessed and assigned
    ## using the indexing operator (`[]`). Use the `slice` method to initialize
    ## a `Nibbles` from a range of nibbles in another `Nibbles` or `Nibbles64`.
    #
    # Note: there's some memory waste when storing just a few nibbles, but using
    #       a `seq` wouldn't have helped; a seq uses two ints, a pointer to heap
    #       memory and some minimum heap allocation, ending up taking 32 bytes
    #       or more (at least on x64), with extra overhead due to non-locality,
    #       fragmentation and GC.
    bytes: array[32, byte]


func `[]`*(nibbles: Nibbles64, pos: range[0..63]): uint8 =
  ## Returns the nibble at the logical `pos`ition
  if pos mod 2 == 0: nibbles.bytes[pos div 2] shr 4
  else: nibbles.bytes[pos div 2] and 0xf


func `[]=`*(nibbles: var Nibbles64, pos: range[0..63], nibble: range[0..15]) =
  ## Stores `nibble` at the logical `pos`ition
  let current = nibbles.bytes[pos div 2]
  if pos mod 2 == 0:
    nibbles.bytes[pos div 2] = (current and 0xf0) or nibble.byte
  else: nibbles.bytes[pos div 2] = (current and 0xf) or (nibble.byte shl 4)


func len*(nibbles: Nibbles): int = nibbles.bytes[31].int
  ## Returns the number of nibbles stored


func `[]`*(nibbles: Nibbles, pos: range[0..61]): uint8 =
  ## Returns the nibble at the logical `pos`ition. If the position is outside of
  ## the range of held nibbles, a `RangeDefect` exception is raised.
  if pos.uint8 >= nibbles.bytes[31]:
    raise newException(RangeDefect, "Out of range nibble at position " & $pos & "; length is " & $nibbles.bytes[31].uint8)
  if pos mod 2 == 0: nibbles.bytes[pos div 2] shr 4
  else: nibbles.bytes[pos div 2] and 0xf


func `[]=`*(nibbles: var Nibbles, pos: range[0..61], nibble: range[0..15]) =
  ## Stores `nibble` at the logical `pos`ition. If the position is outside of
  ## the range of held nibbles, a `RangeDefect` exception is raised.
  if pos.uint8 >= nibbles.bytes[31]:
    raise newException(RangeDefect, "Out of range nibble at position " & $pos & "; length is " & $nibbles.bytes[31].uint8)
  if pos mod 2 == 0:
    nibbles.bytes[pos div 2] = (nibbles.bytes[pos div 2] and 0xf) or (nibble.byte shl 4)
  else: nibbles.bytes[pos div 2] = (nibbles.bytes[pos div 2] and 0xf0) or nibble.byte


func slice*(nibbles: Nibbles64, start: range[0..61], length: range[0..62]): Nibbles =
  ## Initializes a `Nibbles` instance from a range within a `Nibbles64`
  ## instance, denoted by `start` and `length`. The nibbles are copied over, not
  ## referenced. In case `start` + `length` exceed 64, a `RangeDefect` exception
  ## is raised.
  if start + length > 64:
    raise newException(RangeDefect, "Can't initialize nibbles slice with start=" & $start & " and length=" & $length & "; exceeds 64")
  result.bytes[31] = length.uint8
  var pos = 0
  for i in start.int ..< start + length:
    result[pos] = nibbles[i]
    inc pos


func slice*(nibbles: Nibbles, start: range[0..61], length: range[0..62]): Nibbles =
  ## Initializes a `Nibbles` instance from a range within another instance,
  ## denoted by `start` and `length`. The nibbles are copied over, not
  ## referenced. In case `start` + `length` exceed the number of nibbles in the
  ## source, a `RangeDefect` exception is raised.
  if start + length > nibbles.len:
    raise newException(RangeDefect, "Can't initialize nibbles slice with start=" & $start & " and length=" & $length & "; exceeds " & $nibbles.len)
  result.bytes[31] = length.uint8
  var pos = 0
  for i in start.int ..< start + length:
    result[pos] = nibbles[i]
    inc pos
