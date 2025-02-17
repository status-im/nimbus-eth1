# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  eth/common/hashes,
  results,
  ./aristo_desc

# Info snippet (just a reminder to keep somewhere)
#
# Extension of a compact encoded as prefixed sequence of nibbles (i.e.
# half bytes with 4 bits.)
#
#   pfx | bits | vertex type | layout
#   ----+ -----+-------------+----------------------------------------
#    0  | 0000 | extension   | @[<pfx, ignored>,      nibble-pair, ..]
#    1  | 0001 | extension   | @[<pfx, first-nibble>, nibble-pair, ..]
#    2  | 0010 | leaf        | @[<pfx, ignored>,      nibble-pair, ..]
#    3  | 0011 | leaf        | @[<pfx, first-nibble>, nibble-pair, ..]
#
# where the `ignored` part is typically expected a zero nibble.

func pathPfxPad*(pfx: NibblesBuf; dblNibble: static[byte]): NibblesBuf

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func pathAsBlob*(tag: PathID): seq[byte] =
  ## Convert the `tag` argument to a sequence of an even number of nibbles
  ## represented by a `seq[byte]`. If the argument `tag` represents an odd
  ## number of nibbles, a zero nibble is appendend.
  ##
  ## This function is useful only if there is a tacit agreement that all paths
  ## used to index database leaf values can be represented as `seq[byte]`, i.e.
  ## `PathID` type paths with an even number of nibbles.
  if 0 < tag.length:
    let key = tag.pfx.toBytesBE
    if 64 <= tag.length:
      return @key
    else:
      return key[0 .. (tag.length - 1) div 2]

func pathToTag*(partPath: NibblesBuf): Result[PathID,AristoError] =
  ## Convert the argument `partPath`  to a `PathID` type value.
  if partPath.len == 0:
    return ok VOID_PATH_ID
  if partPath.len <= 64:
    return ok PathID(
      pfx:    UInt256.fromBytesBE partPath.pathPfxPad(0).getBytes(),
      length: partPath.len.uint8)
  err(PathAtMost64Nibbles)

func pathToTag*(partPath: openArray[byte]): Result[PathID,AristoError] =
  ## Variant of `pathToTag()`
  if partPath.len == 0:
    return ok VOID_PATH_ID
  if partPath.len <= 32:
    return ok PathID(
      pfx:    UInt256.fromBytesBE @partPath & 0u8.repeat(32-partPath.len),
      length: 2 * partPath.len.uint8)
  err(PathAtMost64Nibbles)

# --------------------

func pathPfxPad*(pfx: NibblesBuf; dblNibble: static[byte]): NibblesBuf =
  ## Extend (or cut) the argument nibbles sequence `pfx` for generating a
  ## `NibblesBuf` with exactly 64 nibbles, the equivalent of a path key.
  ##
  ## This function must be handled with some care regarding a meaningful value
  ## for the `dblNibble` argument. Currently, only static values `0` and `255`
  ## are allowed for padding. This is checked at compile time.
  static:
    doAssert dblNibble == 0 or dblNibble == 255

  let padLen = 64 - pfx.len
  if 0 <= padLen:
    result = pfx & NibblesBuf.fromBytes(dblNibble.repeat(padLen div 2).mapIt(it.byte))
    if (padLen and 1) == 1:
      result = result & NibblesBuf.nibble(dblNibble.byte)
  else:
    let nope = NibblesBuf()
    result = pfx.slice(0,64) & nope # nope forces re-alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
