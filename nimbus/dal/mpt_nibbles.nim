#[  Nimbus
    Copyright (c) 2021-2024 Status Research & Development GmbH
    Licensed and distributed under either of
      * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
      * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
    at your option. This file may not be copied, modified, or distributed except according to those terms. ]#


##[ This module provides data structures for working with 'nibbles'. A nibble is a 4-bit value. To
    save on RAM, we store two nibbles per byte. We provide methods for accessing logical nibbles
    instead of bytes. We use a non-ref backing array for better performance.

    Use `Nibbles` in case you need to represent arbitrary paths in a MPT tree (up to 64 nibbles
    long); it uses 33 bytes of memory (possibly 40 due to memory alignment).
    
    Use `Nibbles62` to represent arbitrary paths in a MPT tree that are no longer than 62 nibbles,
    as is the case with MPT extension nodes. It uses 32 bytes of memory.

    Use `Nibbles64` to represent a leaf path (full 64 nibbles); it uses 32 bytes of memory and no
    range checks when accessing nibbles (better performance). ]##

import ./utils

type

  Nibbles* = object
    ##[ Holds up to 64 nibbles in a fixed 32-bytes array. Nibbles are accessed and assigned using
        the indexing operator (`[]`). The number of nibbles is stored in a separate byte, which
        might cause additional RAM usage due to memory alignment (+7 bytes in x64 CPUs). Consider
        using the more specialized `Nibbles62` or `Nibbles64` to avoid that. ]##

    #[ Note: There's some memory waste when storing just a few nibbles, but using a `seq` wouldn't
       have helped; a seq uses two ints, a pointer to heap memory and some minimum heap allocation,
       ending up taking 32 bytes or more (at least on x64), with performance overheads due to non-
       locality, fragmentation and GC. ]#
    bytes*: array[32, byte]
    len*: uint8


  Nibbles62* = object
    ##[ Holds up to 62 nibbles (the maximum that an extension node in a MPT tree can have), in a
        fixed 32 bytes array. Nibbles are accessed and assigned using the indexing operator (`[]`).
        Use the `slice` method to initialize a `Nibbles` from a range of nibbles in another
        `Nibbles62` or `Nibbles64`. The number of nibbles held is stored in the last byte of the
        underlying array. In case the number of nibbles is odd, they're shifted by half a byte such
        that the first byte starts with 0x0. This can be leveraged for copying the rest of the bytes
        in bulk during RLP encoding. ]##
    bytes*: array[32, byte]


  Nibbles64* = object
    ## Holds 64 nibbles in a fixed 32-bytes array. Nibbles are accessed and assigned using the
    ## indexing operator (`[]`).
    bytes*: array[32, byte]


# ==== Nibbles64 ===================================================================================


func `[]`*(nibbles: Nibbles64, pos: range[0..63]): range[0..15] =
  ## Returns the nibble at the logical `pos`ition
  if pos mod 2 == 0: nibbles.bytes[pos div 2] shr 4
  else: nibbles.bytes[pos div 2] and 0xf


func `[]=`*(nibbles: var Nibbles64, pos: range[0..63], nibble: range[0..15]) =
  ## Stores `nibble` at the logical `pos`ition
  let current = nibbles.bytes[pos div 2]
  if pos mod 2 == 0:
    nibbles.bytes[pos div 2] = (current and 0xf) or (nibble.byte shl 4)
  else: nibbles.bytes[pos div 2] = (current and 0xf0) or nibble.byte


iterator enumerate*(nibbles: Nibbles64): uint8 =
  ## Iterates over the nibbles
  for b in nibbles.bytes:
    yield b shr 4
    yield b and 0xf


func `$`*(nibbles: Nibbles64): string =
  ## Hex encoded nibbles, excluding `0x` prefix
  nibbles.bytes.toHex


# ==== Nibbles62 ===================================================================================


func len*(nibbles: Nibbles62): int =
  ## Returns the number of nibbles stored
  nibbles.bytes[31].int


iterator enumerate*(nibbles: Nibbles62): uint8 =
  ## Iterates over the nibbles
  let len = nibbles.bytes[31].int
  if len mod 2 == 0:
    for i in 0 ..< len div 2:
      yield nibbles.bytes[i] shr 4
      yield nibbles.bytes[i] and 0xf
  else:
    yield nibbles.bytes[0]
    for i in 1 .. len div 2:
      yield nibbles.bytes[i] shr 4
      yield nibbles.bytes[i] and 0xf


func `$`*(nibbles: Nibbles62): string =
  ## Hex encoded nibbles, excluding `0x` prefix
  for nibble in nibbles.enumerate():
    result.add nibble.bitsToHex


func `[]`*(nibbles: Nibbles62, pos: range[0..61]): range[0..15] =
  ## Returns the nibble at the logical `pos`ition. If the position is outside of the range of held
  ## nibbles, a `RangeDefect` exception is raised.
  if pos.uint8 >= nibbles.bytes[31]:
    raise newException(RangeDefect, "Out of range nibble at position " & $pos & "; length is " & $nibbles.bytes[31].uint8)
  if nibbles.bytes[31] mod 2 == 0:
    if pos mod 2 == 0: nibbles.bytes[pos div 2] shr 4
    else: nibbles.bytes[pos div 2] and 0xf
  else:
    if pos mod 2 == 0: nibbles.bytes[pos div 2] and 0xf
    else: nibbles.bytes[(pos+1) div 2] shr 4


func `[]=`*(nibbles: var Nibbles62, pos: range[0..61], nibble: range[0..15]) =
  ## Stores `nibble` at the logical `pos`ition. If the position is outside of the range of held
  ## nibbles, a `RangeDefect` exception is raised.
  if pos.uint8 >= nibbles.bytes[31]:
    raise newException(RangeDefect, "Out of range nibble at position " & $pos & "; length is " & $nibbles.bytes[31].uint8)
  if nibbles.bytes[31] mod 2 == 0:
    if pos mod 2 == 0:
      nibbles.bytes[pos div 2] = (nibbles.bytes[pos div 2] and 0xf) or (nibble.byte shl 4)
    else: nibbles.bytes[pos div 2] = (nibbles.bytes[pos div 2] and 0xf0) or nibble.byte
  else:
    if pos mod 2 == 0:
      nibbles.bytes[pos div 2] = (nibbles.bytes[pos div 2] and 0xf0) or nibble.byte
    else: nibbles.bytes[(pos+1) div 2] = (nibbles.bytes[(pos+1) div 2] and 0xf) or (nibble.byte shl 4)


func slice*(nibbles: Nibbles62, start: range[0..61], length: range[1..62]): Nibbles62 =
  ##[ Initializes a `Nibbles62` instance from a range within another instance, denoted by `start`
      and `length`. The nibbles are copied over, not referenced. In case `start` + `length` exceed
      the number of nibbles in the source, a `RangeDefect` exception is raised. ]##
  # PERF TODO: This can probably be optimized
  if start + length > nibbles.len:
    raise newException(RangeDefect, "Can't initialize nibbles slice with start=" & $start & " and length=" & $length & "; exceeds " & $nibbles.len)
  result.bytes[31] = length.uint8
  var pos = 0
  for i in start.int ..< start + length:
    result[pos] = nibbles[i]
    inc pos


# ==== Nibbles =====================================================================================


func `[]`*(nibbles: Nibbles, pos: range[0..63]): range[0..15] =
  ## Returns the nibble at the logical `pos`ition
  if pos.uint8 >= nibbles.len:
    raise newException(RangeDefect, "Out of range nibble at position " & $pos & "; length is " & $nibbles.len.uint8)
  if pos mod 2 == 0: nibbles.bytes[pos div 2] shr 4
  else: nibbles.bytes[pos div 2] and 0xf


func `[]=`*(nibbles: var Nibbles, pos: range[0..63], nibble: range[0..15]) =
  ## Stores `nibble` at the logical `pos`ition
  if pos.uint8 >= nibbles.len:
    raise newException(RangeDefect, "Out of range nibble at position " & $pos & "; length is " & $nibbles.len.uint8)
  let current = nibbles.bytes[pos div 2]
  if pos mod 2 == 0:
    nibbles.bytes[pos div 2] = (current and 0xf) or (nibble.byte shl 4)
  else: nibbles.bytes[pos div 2] = (current and 0xf0) or nibble.byte


func append*(nibbles: Nibbles, nibble: range[0..15]): Nibbles {.noinit.} =
  ## Returns a clone of `nibbles` with the `nibble` appended to it.
  if nibbles.len >= 64:
    raise newException(RangeDefect, "Can't append a nibble; 64 nibbles in use")
  result = nibbles
  inc result.len
  result[nibbles.len] = nibble


func slice*(nibbles: Nibbles64, start: range[0..63], length: range[0..64]): Nibbles =
  ##[ Initializes a `Nibbles` instance from a range within a `Nibbles64` instance, denoted by
      `start` and `length`. The nibbles are copied over, not referenced. In case `start` + `length`
      exceed 64, a `RangeDefect` exception is raised. ]##
  # PERF TODO: This can probably be optimized
  if start + length > 64:
    raise newException(RangeDefect, "Can't initialize nibbles slice with start=" & $start & " and length=" & $length & "; exceeds 64")
  result.len = length.uint8
  var pos = 0
  for i in start.int ..< start + length:
    result[pos] = nibbles[i]
    inc pos


iterator enumerate*(nibbles: Nibbles): uint8 =
  ## Iterates over the nibbles
  for i in 0 ..< nibbles.len.int div 2:
    yield nibbles.bytes[i] shr 4
    yield nibbles.bytes[i] and 0xf
  if nibbles.len mod 2 == 1:
    yield nibbles.bytes[nibbles.len div 2] shr 4


func `$`*(nibbles: Nibbles): string =
  ## Hex encoded nibbles, excluding `0x` prefix
  for nibble in nibbles.enumerate():
    result.add nibble.bitsToHex


func append*(nibbles: Nibbles, otherNibs: Nibbles): Nibbles {.noinit.} =
  ## Returns a clone of `nibbles` with the content of `otherNibs` appended to it.
  if nibbles.len + otherNibs.len.uint8 > 64:
    raise newException(RangeDefect, "Can't append a nibbles62; exceeds 64")
  result = nibbles
  for n in otherNibs.enumerate():
    inc result.len
    result[result.len - 1] = n


func slice*(nibbles: Nibbles, start: range[0..63], length: range[0..64]): Nibbles =
  ##[ Initializes a `Nibbles` instance from a range within another `Nibbles` instance, denoted by
      `start` and `length`. The nibbles are copied over, not referenced. In case `start` + `length`
      exceed 64, a `RangeDefect` exception is raised. ]##
  # PERF TODO: This can probably be optimized
  if start + length > 64:
    raise newException(RangeDefect, "Can't initialize nibbles slice with start=" & $start & " and length=" & $length & "; exceeds 64")
  result.len = length.uint8
  var pos = 0
  for i in start.int ..< start + length:
    result[pos] = nibbles[i]
    inc pos
