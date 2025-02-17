# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results
export results

#Parses specific data from a given channel if given in following binary format:
# (array size Uint) | [ (element size Uint) (element data)]
proc parseChannelData*(p: pointer): Result[seq[string], string] =
  # Start reading from base pointer
  var readOffset = cast[uint](p)
  var recoveredStrings: seq[string]
  var totalSize: uint = 0

  # length
  copyMem(addr totalSize, cast[pointer](readOffset), sizeof(uint))
  readOffset += uint(sizeof(uint))

  while readOffset < cast[uint](p) + totalSize:
    #seq element size
    var strLen: uint
    copyMem(addr strLen, cast[pointer](readOffset), sizeof(uint))
    readOffset += uint(sizeof(uint))

    #element
    var strData = newString(strLen)
    copyMem(addr strData[0], cast[pointer](readOffset), uint(strLen))
    readOffset += uint(strLen)

    recoveredStrings.add(strData)

  ok recoveredStrings
