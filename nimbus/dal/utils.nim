#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.

##  This module provides a collection of utility methods

import std/[streams, strformat]


func bitsToHex*(b: byte): char =
  ## Converts a uint4 to a lowercase hex char
  case b
    of 0:  result = '0'
    of 1:  result = '1'
    of 2:  result = '2'
    of 3:  result = '3'
    of 4:  result = '4'
    of 5:  result = '5'
    of 6:  result = '6'
    of 7:  result = '7'
    of 8:  result = '8'
    of 9:  result = '9'
    of 10: result = 'a'
    of 11: result = 'b'
    of 12: result = 'c'
    of 13: result = 'd'
    of 14: result = 'e'
    of 15: result = 'f'
    else: raise newException(ValueError, "Given byte must be uint4 (0-15)")


func hexToBits*(c: char): byte =
  ## Converts a hex char to a uint4
  case c
    of '0': result = 0
    of '1': result = 1
    of '2': result = 2
    of '3': result = 3
    of '4': result = 4
    of '5': result = 5
    of '6': result = 6
    of '7': result = 7
    of '8': result = 8
    of '9': result = 9
    of 'a', 'A': result = 10
    of 'b', 'B': result = 11
    of 'c', 'C': result = 12
    of 'd', 'D': result = 13
    of 'e', 'E': result = 14
    of 'f', 'F': result = 15
    else: raise newException(ValueError, "Character must be hexadecimal (a-f | A-F | 0-9)")


func toHex*(b: byte): string =
  result.add bitsToHex(b shr 4)
  result.add bitsToHex(b and 0x0f)


proc writeAsHex*(stream: Stream, b: byte) =
  ## Writes a byte to the stream as two hex characters
  stream.write(bitsToHex(b shr 4))
  stream.write(bitsToHex(b and 0x0f))


proc writeAsHex*(stream: Stream, bytes: openArray[byte]) =
  ## Writes a byte array to the stream as hex characters
  for b in bytes:
    stream.writeAsHex(b)


func toHex*(bytes: openArray[byte]): string =
  ## Converts a bytes array into a newly-allocated hex-encoded string
  for b in bytes:
    result.add bitsToHex(b shr 4)
    result.add bitsToHex(b and 0x0f)


iterator hexToBytes*(s: string): byte =
  ## Converts a hex string into a bytes sequence
  if s.len mod 2 == 1:
    raise newException(ValueError, "Hex string length must be even")
  var i=0
  while i < s.len:
    let c1 = s[i].hexToBits
    inc i
    let c2 = s[i].hexToBits
    inc i
    yield c1 shl 4 or c2


func hexToBytesArray*[T: static int](str: string): array[T, byte] =
  ## Converts a hex string into a fixed-size bytes array
  if str.len != T*2:
    raise newException(ValueError, &"Hex string length is {str.len}; expected {T*2}")
  var i = 0
  for b in str.hexToBytes:
    result[i] = b
    inc i


func firstMatchAt*[T](s: seq[T], pred: proc(x: T): bool {.closure.}):
                    tuple[found: bool, index: uint] {.effectsOf: pred.} =
  ## Returns the index of the first element in a sequence matching the given
  ## `pred`icate, if any.
  var index = 0u
  for item in s:
    if pred(item):
      return (true, index)
    inc(index)
  (false, index)

