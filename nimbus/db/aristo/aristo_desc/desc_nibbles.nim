# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [], gcsafe, noinline.}

import stew/[arraybuf, arrayops, bitops2, endians2, staticfor]

export arraybuf

type
  NibblesBuf* = object
    ## Allocation-free type for storing up to 64 4-bit nibbles, as seen in the
    ## Ethereum MPT
    limbs: array[4, uint64]
      # Each limb holds 16 nibbles in big endian order - for buffers shorter
      # 64 nibbles we make sure the last limb holding any data is zero-padded
      # (so as to avoid UB on uninitialized reads) - for example a buffer
      # holding one nibble will have one fully initialized limb and 3
      # uninitialized limbs.
    iend: uint8
      # Where valid nibbles can be found - we use indices here to avoid copies
      # wen slicing - iend not inclusive

  HexPrefixBuf* = ArrayBuf[33, byte]

func high*(T: type NibblesBuf): int =
  63

func nibble*(T: type NibblesBuf, nibble: byte): T {.noinit.} =
  result.limbs[0] = uint64(nibble) shl (64 - 4)
  result.iend = 1

template limb(i: int | uint8): uint8 =
  # In which limb can nibble i be found?
  uint8(i) shr 4 # shr 4 = div 16 = 16 nibbles per limb

template shift(i: int | uint8): int =
  # How many bits to shift to find nibble i within its limb?
  60 - ((i mod 16) shl 2) # shl 2 = 4 bits per nibble

func `[]`*(r: NibblesBuf, i: int): byte =
  let
    ilimb = i.limb
    ishift = i.shift
  byte((r.limbs[ilimb] shr ishift) and 0x0f)

func `[]=`*(r: var NibblesBuf, i: int, v: byte) =
  let
    ilimb = i.limb
    ishift = i.shift

  r.limbs[ilimb] =
    (uint64(v and 0x0f) shl ishift) or ((r.limbs[ilimb] and not (0x0f'u64 shl ishift)))

func fromBytes*(T: type NibblesBuf, bytes: openArray[byte]): T {.noinit.} =
  if bytes.len >= 32:
    result.iend = 64
    staticFor i, 0 ..< result.limbs.len:
      const pos = i * 8 # 16 nibbles per limb, 2 nibbles per byte
      result.limbs[i] = uint64.fromBytesBE(bytes.toOpenArray(pos, pos + 7))
  else:
    let blen = uint8(bytes.len)
    result.iend = blen * 2

    block done:
      staticFor i, 0 ..< result.limbs.len:
        const pos = i * 8
        if pos + 7 < blen:
          result.limbs[i] = uint64.fromBytesBE(bytes.toOpenArray(pos, pos + 7))
        else:
          if pos < blen:
            var tmp = 0'u64
            var shift = 56'u8
            for j in uint8(pos) ..< blen:
              tmp = tmp or uint64(bytes[j]) shl shift
              shift -= 8

            result.limbs[i] = tmp
          break done

func len*(r: NibblesBuf): int =
  int(r.iend)

func `$`*(r: NibblesBuf): string =
  result = newStringOfCap(64)
  for i in 0 ..< r.len:
    const chars = "0123456789abcdef"
    result.add chars[r[i]]

func `==`*(lhs, rhs: NibblesBuf): bool =
  if lhs.iend != rhs.iend:
    return false

  staticFor i, 0 ..< lhs.limbs.len:
    if uint8(i * 16) >= lhs.iend:
      return true
    if lhs.limbs[i] != rhs.limbs[i]:
      return false
  true

func sharedPrefixLen*(lhs, rhs: NibblesBuf): int =
  let len = min(lhs.iend, rhs.iend)
  staticFor i, 0 ..< lhs.limbs.len:
    const pos = i * 16

    if (pos + 16) >= len or lhs.limbs[i] != rhs.limbs[i]:
      return
        if pos < len:
          let mask =
            if len - pos >= 16:
              0'u64
            else:
              (not 0'u64) shr ((len - pos) * 4)
          pos + leadingZeros((lhs.limbs[i] xor rhs.limbs[i]) or mask) shr 2
        else:
          pos

  64

func startsWith*(lhs, rhs: NibblesBuf): bool =
  sharedPrefixLen(lhs, rhs) == rhs.len

func slice*(r: NibblesBuf, ibegin: int, iend = -1): NibblesBuf {.noinit.} =
  let e =
    if iend < 0:
      min(64, r.len + iend + 1)
    else:
      min(64, iend)

  # With noinit, we have to be careful not to read result.bytes
  result.iend = uint8(e - ibegin)

  var ilimb = ibegin.limb
  block done:
    let shift = (ibegin mod 16) shl 2
    if shift == 0: # Must be careful not to shift by 64 which is UB!
      staticFor i, 0 ..< result.limbs.len:
        if uint8(i * 16) >= result.iend:
          break done
        result.limbs[i] = r.limbs[ilimb]
        ilimb += 1
    else:
      staticFor i, 0 ..< result.limbs.len:
        if uint8(i * 16) >= result.iend:
          break done

        let cur = r.limbs[ilimb] shl shift
        ilimb += 1

        result.limbs[i] =
          if (ilimb * 16) < uint8 r.iend:
            let next = r.limbs[ilimb] shr (64 - shift)
            cur or next
          else:
            cur

template copyshr(aend: uint8) =
  block adone: # copy aend nibbles of a
    staticFor i, 0 ..< result.limbs.len:
      if uint8(i * 16) >= aend:
        break adone

      result.limbs[i] = a.limbs[i]

  block bdone:
    let shift = (aend mod 16) shl 2

    var alimb = aend.limb

    if shift == 0:
      staticFor i, 0 ..< result.limbs.len:
        if uint8(i * 16) >= b.iend:
          break bdone

        result.limbs[alimb] = b.limbs[i]
        alimb += 1
    else:
      # remove the part of a that should be b from the last a limb
      result.limbs[alimb] = result.limbs[alimb] and ((not 0'u64) shl (64 - shift))

      staticFor i, 0 ..< result.limbs.len:
        if uint8(i * 16) >= b.iend:
          break bdone

        # reading result.limbs here is safe because because the previous loop
        # iteration will have initialized it (or the a copy on initial iteration)
        result.limbs[alimb] = result.limbs[alimb] or b.limbs[i] shr shift

        alimb += 1
        if (alimb * 16) < result.iend:
          result.limbs[alimb] = b.limbs[i] shl (64 - shift)

func `&`*(a, b: NibblesBuf): NibblesBuf {.noinit.} =
  result.iend = min(64'u8, a.iend + b.iend)

  let aend = a.iend
  copyshr(aend)

func replaceSuffix*(a, b: NibblesBuf): NibblesBuf {.noinit.} =
  if b.iend >= a.iend:
    result = b
  elif b.iend == 0:
    result = a
  else:
    result.iend = a.iend

    let aend = a.iend - b.iend
    copyshr(aend)

func toHexPrefix*(r: NibblesBuf, isLeaf = false): HexPrefixBuf {.noinit.} =
  # We'll adjust to the actual length below, but this hack allows us to write
  # full limbs

  result.n = 33 # careful with noinit, to not call setlen
  let
    limbs = (r.iend + 15).limb
    isOdd = (r.iend and 1) > 0

  result[0] = (byte(isLeaf) * 2 + byte(isOdd)) shl 4

  if isOdd:
    result[0] = result[0] or byte(r.limbs[0] shr 60)

    staticFor i, 0 ..< r.limbs.len:
      if i < limbs:
        let next =
          when i == r.limbs.high:
            0'u64
          else:
            r.limbs[i + 1]
        let limb = r.limbs[i] shl 4 or next shr 60

        const pos = i * 8 + 1
        assign(result.data.toOpenArray(pos, pos + 7), limb.toBytesBE())
  else:
    staticFor i, 0 ..< r.limbs.len:
      if i < limbs:
        let limb = r.limbs[i]
        const pos = i * 8 + 1
        assign(result.data.toOpenArray(pos, pos + 7), limb.toBytesBE())

  result.setLen(int((r.iend shr 1) + 1))

func fromHexPrefix*(
    T: type NibblesBuf, bytes: openArray[byte]
): tuple[isLeaf: bool, nibbles: NibblesBuf] {.noinit.} =
  if bytes.len > 0:
    result.isLeaf = (bytes[0] and 0x20) != 0
    let hasOddLen = (bytes[0] and 0x10) != 0

    if hasOddLen:
      let high = uint8(min(31, bytes.len - 1))
      result.nibbles =
        NibblesBuf.nibble(bytes[0] and 0x0f) &
        NibblesBuf.fromBytes(bytes.toOpenArray(1, int high))
    else:
      result.nibbles = NibblesBuf.fromBytes(bytes.toOpenArray(1, bytes.high()))
  else:
    result.isLeaf = false
    result.nibbles.iend = 0

func getBytes*(a: NibblesBuf): array[32, byte] =
  staticFor i, 0 ..< a.limbs.len:
    const pos = i * 8
    assign(result.toOpenArray(pos, pos + 7), a.limbs[i].toBytesBE)
