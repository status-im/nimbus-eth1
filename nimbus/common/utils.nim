# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/[strutils], results, chronicles, stew/shims/macros, confutils, ../conf

logScope:
  topics = "utils"

## Macro that collects names and abbreviations per layer from configuration
macro extractFieldNames*(configType: typed): untyped =
  var names: seq[string] = newSeq[string]()
  let recDef = configType.getImpl()

  for field in recordFields(recDef):
    let
      name = field.readPragma("name")
      abbr = field.readPragma("abbr")

    if name.kind == nnkNilLit:
      continue

    names.add($name)

    if abbr.kind != nnkNilLit:
      names.add($abbr)

  result = quote:
    `names . mapIt ( newLit ( it ))`

## Write a string into a raw memory buffer (prefixed with length)
proc writeConfigString*(offset: var uint, elem: string) =
  if offset <= 0:
    fatal "memory offset can't be zero"
    quit(QuitFailure)

  let optLen = uint(elem.len)
  copyMem(cast[pointer](offset), addr optLen, sizeof(uint))
  offset += uint(sizeof(uint))

  if optLen > 0:
    copyMem(cast[pointer](offset), unsafeAddr elem[0], elem.len)
    offset += uint(elem.len)

## Read a string from a raw memory buffer (expects length prefix)
proc readConfigString*(offset: var uint): string =
  var strLen: uint
  copyMem(addr strLen, cast[pointer](offset), sizeof(uint))
  offset += uint(sizeof(uint))

  var strData = ""
  if strLen > 0:
    strData = newString(strLen)
    copyMem(addr strData[0], cast[pointer](offset), uint(strLen))
    offset += uint(strLen)

  strData

## Parse configuration options from a memory block.
## Format: (table size:uint) | [ (key size:uint)(key:string) (val size:uint)(val:string) ]*
proc deserializeConfigArgs*(p: pointer): Result[seq[string], string] =
  var
    readOffset = cast[uint](p)
    optionsList = newSeq[string]()
    totalSize: uint = 0

  copyMem(addr totalSize, cast[pointer](readOffset), sizeof(uint))
  readOffset += uint(sizeof(uint))

  while readOffset < cast[uint](p) + totalSize:
    let
      optName = readConfigString(readOffset)
      arg = readConfigString(readOffset)
      option = optName & arg

    optionsList.add(option)

  ok optionsList
