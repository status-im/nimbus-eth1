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
  EthAddressStr* = distinct string  # Same as HexDataStr but must be less <= 20 bytes
  EthHashStr* = distinct string     # Same as HexDataStr but must be exactly 32 bytes

func len*(quantity: HexQuantityStr): int = quantity.string.len
func len*(data: HexDataStr): int = data.string.len
func len*(data: EthAddressStr): int = data.string.len
func len*(data: EthHashStr): int = data.string.len

# Hex validation

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

func encodeQuantity*(value: SomeUnsignedInt): string {.inline.} =
  var hValue = value.toHex.stripLeadingZeros
  result = "0x" & hValue

template hasHexHeader(value: string): bool =
  if value.len >= 2 and value[0] == '0' and value[1] in {'x', 'X'}: true
  else: false

template isHexChar(c: char): bool =
  if  c notin {'0'..'9'} and
      c notin {'a'..'f'} and
      c notin {'A'..'F'}: false
  else: true

func isValidHexQuantity*(value: string): bool =
  if not value.hasHexHeader:
    return false
  # No leading zeros (but allow 0x0)
  if value.len < 3 or (value.len > 3 and value[2] == '0'): return false
  for i in 2 ..< value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  return true

func isValidHexData*(value: string): bool =
  if not value.hasHexHeader:
    return false
  # Must be even number of digits
  if value.len mod 2 != 0: return false
  # Leading zeros are allowed
  for i in 2 ..< value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  return true

func isValidEthAddress*(value: string): bool =
  # 20 bytes for EthAddress plus "0x"
  # Addresses are allowed to be shorter than 20 bytes for convenience
  result = value.len <= 42 and value.isValidHexData

func isValidEthHash*(value: string): bool =
  # 32 bytes for EthAddress plus "0x"
  # Currently hashes are required to be exact lengths
  # TODO: Allow shorter hashes (pad with zeros) for convenience?
  result = value.len == 66 and value.isValidHexData

const
  SInvalidQuantity = "Invalid hex quantity format for Ethereum"
  SInvalidData = "Invalid hex data format for Ethereum"
  SInvalidAddress = "Invalid address format for Ethereum"
  SInvalidHash = "Invalid hash format for Ethereum"

proc validateHexQuantity*(value: string) {.inline.} =
  if unlikely(not value.isValidHexQuantity):
    raise newException(ValueError, SInvalidQuantity & ": " & value)

proc validateHexData*(value: string) {.inline.} =
  if unlikely(not value.isValidHexData):
    raise newException(ValueError, SInvalidData & ": " & value)

proc validateHexAddressStr*(value: string) {.inline.} =
  if unlikely(not value.isValidEthAddress):
    raise newException(ValueError, SInvalidAddress & ": " & value)

proc validateHashStr*(value: string) {.inline.} =
  if unlikely(not value.isValidEthHash):
    raise newException(ValueError, SInvalidHash & ": " & value)

# Initialisation

proc hexQuantityStr*(value: string): HexQuantityStr {.inline.} =
  value.validateHexQuantity
  result = value.HexQuantityStr

proc hexDataStr*(value: string): HexDataStr {.inline.} =
  value.validateHexData
  result = value.HexDataStr

proc ethAddressStr*(value: string): EthAddressStr {.inline.} =
  value.validateHexAddressStr
  result = value.EthAddressStr

proc ethHashStr*(value: string): EthHashStr {.inline.} =
  value.validateHashStr
  result = value.EthHashStr

# Converters for use in RPC

import json
from json_rpc/rpcserver import expect

proc `%`*(value: HexQuantityStr): JsonNode =
  result = %(value.string)

proc `%`*(value: HexDataStr): JsonNode =
  result = %(value.string)

proc `%`*(value: EthAddressStr): JsonNode =
  result = %(value.string)

proc `%`*(value: EthHashStr): JsonNode =
  result = %(value.string)

proc fromJson*(n: JsonNode, argName: string, result: var HexQuantityStr) =
  # Note that '0x' is stripped after validation
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidHexQuantity:
    raise newException(ValueError, "Parameter \"" & argName & "\" is not valid as an Ethereum hex quantity \"" & hexStr & "\"")
  result = hexStr.hexQuantityStr

proc fromJson*(n: JsonNode, argName: string, result: var HexDataStr) =
  # Note that '0x' is stripped after validation
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidHexData:
    raise newException(ValueError, "Parameter \"" & argName & "\" is not valid as Ethereum data \"" & hexStr & "\"")
  result = hexStr.hexDataStr

proc fromJson*(n: JsonNode, argName: string, result: var EthAddressStr) =
  # Note that '0x' is stripped after validation
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidEthAddress:
    raise newException(ValueError, "Parameter \"" & argName & "\" is not valid as an Ethereum address \"" & hexStr & "\"")
  result = hexStr.EthAddressStr

proc fromJson*(n: JsonNode, argName: string, result: var EthHashStr) =
  # Note that '0x' is stripped after validation
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidEthHash:
    raise newException(ValueError, "Parameter \"" & argName & "\" is not valid as an Ethereum hash \"" & hexStr & "\"")
  result = hexStr.EthHashStr

