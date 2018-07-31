# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements the Ethereum hexadecimal string formats for JSON
## See: https://github.com/ethereum/wiki/wiki/JSON-RPC#hex-value-encoding

type
  HexQuantityStr* = distinct string
  HexDataStr* = distinct string

# Hex validation

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc encodeQuantity*(value: SomeUnsignedInt): string =
  var hValue = value.toHex.stripLeadingZeros
  result = "0x" & hValue

template hasHexHeader*(value: string): bool =
  if value != "" and value[0] == '0' and value[1] in {'x', 'X'} and value.len > 2: true
  else: false

template isHexChar*(c: char): bool =
  if  c notin {'0'..'9'} and
      c notin {'a'..'f'} and
      c notin {'A'..'F'}: false
  else: true

proc validateHexQuantity*(value: string): bool =
  if value.len < 3 or not value.hasHexHeader:
    return false
  # No leading zeros (but allow 0x0)
  if value.len > 3 and value[2] == '0': return false
  for i in 2 ..< value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  return true

proc validateHexData*(value: string): bool =
  if value.len < 3 or not value.hasHexHeader:
    return false
  # Must be even number of digits
  if value.len mod 2 != 0: return false
  # Leading zeros are allowed
  for i in 2 ..< value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  return true

const
  SInvalidQuantity = "Invalid hex quantity format for Ethereum"
  SInvalidData = "Invalid hex data format for Ethereum"

proc validateRaiseHexQuantity*(value: string) =
  if not value.validateHexQuantity:
    raise newException(ValueError, SInvalidQuantity & ": " & value)

proc validateRaiseHexData*(value: string) =
  if not value.validateHexData:
    raise newException(ValueError, SInvalidData & ": " & value)

# Initialisation

proc hexQuantityStr*(value: string): HexQuantityStr =
  value.validateRaiseHexQuantity
  result = value.HexQuantityStr

proc hexDataStr*(value: string): HexDataStr =
  value.validateRaiseHexData
  result = value.HexDataStr

# Converters for use in RPC

import json
from json_rpc/rpcserver import expect

proc `%`*(value: HexQuantityStr): JsonNode =
  result = %(value.string)

proc `%`*(value: HexDataStr): JsonNode =
  result = %(value.string)

proc fromJson*(n: JsonNode, argName: string, result: var HexQuantityStr) =
  # Note that '0x' is stripped after validation
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.validateHexQuantity:
    raise newException(ValueError, "Parameter \"" & argName & "\" is not valid as an Ethereum hex quantity \"" & hexStr & "\"")
  result = hexStr.hexQuantityStr

proc fromJson*(n: JsonNode, argName: string, result: var HexDataStr) =
  # Note that '0x' is stripped after validation
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.validateHexData:
    raise newException(ValueError, "Parameter \"" & argName & "\" is not valid as a Ethereum data \"" & hexStr & "\"")
  result = hexStr.hexDataStr

