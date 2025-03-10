# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, ../conf, chronicles

## Serialize table string elements
proc serializeTableElem*(offset: var uint, elem: string) =
  if offset <= 0:
    fatal "memory offset can't be zero"
    quit(QuitFailure)

  #element size
  let optLen = uint(elem.len)
  copyMem(cast[pointer](offset), addr optLen, sizeof(uint))
  offset += uint(sizeof(uint))

  #element data
  copyMem(cast[pointer](offset), unsafeAddr elem[0], elem.len)
  offset += uint(elem.len)

## Deserialize table string elements
proc deserializeTableElem*(offset: var uint): string =
  #element size
  var strLen: uint
  copyMem(addr strLen, cast[pointer](offset), sizeof(uint))
  offset += uint(sizeof(uint))

  #element
  var strData = newString(strLen)
  copyMem(addr strData[0], cast[pointer](offset), uint(strLen))
  offset += uint(strLen)

  strData

## Parse data from a given channel.
##  schema: (table size:Uint) | [ (option size:Uint) (option data:byte) (arg size: Uint) (arg data:byte)]
proc parseChannelData*(p: pointer): Result[NimbusConfigTable, string] =
  # Start reading from base pointer
  var
    readOffset = cast[uint](p)
    confTable = NimbusConfigTable()
    totalSize: uint = 0

  # length
  copyMem(addr totalSize, cast[pointer](readOffset), sizeof(uint))
  readOffset += uint(sizeof(uint))

  while readOffset < cast[uint](p) + totalSize:
    let opt = deserializeTableElem(readOffset)
    let arg = deserializeTableElem(readOffset)
    confTable[opt] = arg

  ok confTable
