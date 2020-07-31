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

#[
  Note:
  The following types are converted to hex strings when marshalled to JSON:
    * EthAddress
    * ref EthAddress
    * Hash256
    * UInt256
    * seq[byte]
    * openArray[seq]
    * ref BloomFilter
    * PublicKey
    * PrivateKey
    * SymKey
    * Topic
    * Bytes
]#

import
  stint, stew/byteutils, eth/[keys, rlp], eth/common/eth_types,
  eth/p2p/rlpx_protocols/whisper_protocol

type
  HexQuantityStr* = distinct string
  HexDataStr* = distinct string
  EthAddressStr* = distinct string     # Same as HexDataStr but must be less <= 20 bytes
  EthHashStr* = distinct string        # Same as HexDataStr but must be exactly 32 bytes
  Identifier* = distinct string        # 32 bytes, no 0x prefix!
  HexStrings = HexQuantityStr | HexDataStr | EthAddressStr | EthHashStr |
               Identifier

template len*(value: HexStrings): int = value.string.len

# Hex validation

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

func encodeQuantity*(value: SomeUnsignedInt): HexQuantityStr  {.inline.} =
  var hValue = value.toHex.stripLeadingZeros
  result = HexQuantityStr("0x" & hValue)

func encodeQuantity*(value: UInt256): HexQuantityStr  {.inline.} =
  var hValue = value.toHex
  result = HexQuantityStr("0x" & hValue)

template hasHexHeader(value: string): bool =
  if value.len >= 2 and value[0] == '0' and value[1] in {'x', 'X'}: true
  else: false

template isHexChar(c: char): bool =
  if  c notin {'0'..'9'} and
      c notin {'a'..'f'} and
      c notin {'A'..'F'}: false
  else: true

func `==`*(a, b: HexQuantityStr): bool {.inline.} =
  a.string == b.string

func `==`*(a, b: EthAddressStr): bool {.inline.} =
  a.string == b.string

func `==`*(a, b: HexDataStr): bool {.inline.} =
  a.string == b.string

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

func isValidHexData*(value: string, header = true): bool =
  if header and not value.hasHexHeader:
    return false
  # Must be even number of digits
  if value.len mod 2 != 0: return false
  # Leading zeros are allowed
  for i in 2 ..< value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  return true

template isValidHexData(value: string, hexLen: int, header = true): bool =
  value.len == hexLen and value.isValidHexData(header)

func isValidEthAddress*(value: string): bool =
  # 20 bytes for EthAddress plus "0x"
  # Addresses are allowed to be shorter than 20 bytes for convenience
  result = value.len <= 42 and value.isValidHexData

func isValidEthHash*(value: string): bool =
  # 32 bytes for EthAddress plus "0x"
  # Currently hashes are required to be exact lengths
  # TODO: Allow shorter hashes (pad with zeros) for convenience?
  result = value.isValidHexData(66)

func isValidIdentifier*(value: string): bool =
  # 32 bytes for Whisper ID, no 0x prefix
  result = value.isValidHexData(64, false)

func isValidPublicKey*(value: string): bool =
  # 65 bytes for Public Key plus 1 byte for 0x prefix
  result = value.isValidHexData(132)

func isValidPrivateKey*(value: string): bool =
  # 32 bytes for Private Key plus 1 byte for 0x prefix
  result = value.isValidHexData(66)

func isValidSymKey*(value: string): bool =
  # 32 bytes for Private Key plus 1 byte for 0x prefix
  result = value.isValidHexData(66)

func isValidHash256*(value: string): bool =
  # 32 bytes for Hash256 plus 1 byte for 0x prefix
  result = value.isValidHexData(66)

func isValidTopic*(value: string): bool =
  # 4 bytes for Topic plus 1 byte for 0x prefix
  result = value.isValidHexData(10)

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

proc hexDataStr*(value: openArray[byte]): HexDataStr {.inline.} =
  result = HexDataStr("0x" & value.toHex)

proc hexDataStr*(value: Uint256): HexDataStr {.inline.} =
  result = HexDataStr("0x" & toBytesBE(value).toHex)

proc ethAddressStr*(value: string): EthAddressStr {.inline.} =
  value.validateHexAddressStr
  result = value.EthAddressStr

func ethAddressStr*(x: EthAddress): EthAddressStr {.inline.} =
  result = EthAddressStr("0x" & toHex(x))

proc ethHashStr*(value: string): EthHashStr {.inline.} =
  value.validateHashStr
  result = value.EthHashStr

func ethHashStr*(value: Hash256): EthHashStr {.inline.} =
  result = EthHashStr("0x" & value.data.toHex)

# Converters for use in RPC

import json
from json_rpc/rpcserver import expect

proc `%`*(value: HexStrings): JsonNode =
  result = %(value.string)

# Overloads to support expected representation of hex data
proc `%`*(value: EthAddress): JsonNode =
  result = %("0x" & value.toHex)

proc `%`*(value: ref EthAddress): JsonNode =
  result = %("0x" & value[].toHex)

proc `%`*(value: Hash256): JsonNode =
  #result = %("0x" & $value) # More clean but no lowercase :(
  result = %("0x" & value.data.toHex)

proc `%`*(value: UInt256): JsonNode =
  result = %("0x" & value.toString(16))

proc `%`*(value: ref BloomFilter): JsonNode =
  result = %("0x" & toHex[256](value[]))

proc `%`*(value: PublicKey): JsonNode =
  result = %("0x04" & $value)

proc `%`*(value: PrivateKey): JsonNode =
  result = %("0x" & $value)

proc `%`*(value: SymKey): JsonNode =
  result = %("0x" & value.toHex)

proc `%`*(value: whisper_protocol.Topic): JsonNode =
  result = %("0x" & value.toHex)

proc `%`*(value: seq[byte]): JsonNode =
  result = %("0x" & value.toHex)

# Helpers for the fromJson procs

proc toPublicKey*(key: string): PublicKey {.inline.} =
  result = PublicKey.fromHex(key[4 .. ^1]).tryGet()

proc toPrivateKey*(key: string): PrivateKey {.inline.} =
  result = PrivateKey.fromHex(key[2 .. ^1]).tryGet()

proc toSymKey*(key: string): SymKey {.inline.} =
  hexToByteArray(key[2 .. ^1], result)

proc toTopic*(topic: string): whisper_protocol.Topic {.inline.} =
  hexToByteArray(topic[2 .. ^1], result)

# Marshalling from JSON to Nim types that includes format checking

func invalidMsg(name: string): string = "When marshalling from JSON, parameter \"" & name & "\" is not valid"

proc fromJson*(n: JsonNode, argName: string, result: var HexQuantityStr) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidHexQuantity:
    raise newException(ValueError, invalidMsg(argName) & " as an Ethereum hex quantity \"" & hexStr & "\"")
  result = hexStr.hexQuantityStr

proc fromJson*(n: JsonNode, argName: string, result: var HexDataStr) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidHexData:
    raise newException(ValueError, invalidMsg(argName) & " as Ethereum data \"" & hexStr & "\"")
  result = hexStr.hexDataStr

proc fromJson*(n: JsonNode, argName: string, result: var EthAddressStr) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidEthAddress:
    raise newException(ValueError, invalidMsg(argName) & "\" as an Ethereum address \"" & hexStr & "\"")
  result = hexStr.EthAddressStr

proc fromJson*(n: JsonNode, argName: string, result: var EthAddress) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidEthAddress:
    raise newException(ValueError, invalidMsg(argName) & "\" as an Ethereum address \"" & hexStr & "\"")
  hexToByteArray(hexStr, result)

proc fromJson*(n: JsonNode, argName: string, result: var EthHashStr) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidEthHash:
    raise newException(ValueError, invalidMsg(argName) & " as an Ethereum hash \"" & hexStr & "\"")
  result = hexStr.EthHashStr

proc fromJson*(n: JsonNode, argName: string, result: var Identifier) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidIdentifier:
    raise newException(ValueError, invalidMsg(argName) & " as a identifier \"" & hexStr & "\"")
  result = hexStr.Identifier

proc fromJson*(n: JsonNode, argName: string, result: var UInt256) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not (hexStr.len <= 66 and hexStr.isValidHexQuantity):
    raise newException(ValueError, invalidMsg(argName) & " as a UInt256 \"" & hexStr & "\"")
  result = readUintBE[256](hexToPaddedByteArray[32](hexStr))

proc fromJson*(n: JsonNode, argName: string, result: var PublicKey) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidPublicKey:
    raise newException(ValueError, invalidMsg(argName) & " as a public key \"" & hexStr & "\"")
  result = hexStr.toPublicKey

proc fromJson*(n: JsonNode, argName: string, result: var PrivateKey) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidPrivateKey:
    raise newException(ValueError, invalidMsg(argName) & " as a private key \"" & hexStr & "\"")
  result = hexStr.toPrivateKey

proc fromJson*(n: JsonNode, argName: string, result: var SymKey) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidSymKey:
    raise newException(ValueError, invalidMsg(argName) & " as a symmetric key \"" & hexStr & "\"")
  result = toSymKey(hexStr)

proc fromJson*(n: JsonNode, argName: string, result: var whisper_protocol.Topic) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidTopic:
    raise newException(ValueError, invalidMsg(argName) & " as a topic \"" & hexStr & "\"")
  result = toTopic(hexStr)

# Following procs currently required only for testing, the `createRpcSigs` macro
# requires it as it will convert the JSON results back to the original Nim
# types, but it needs the `fromJson` calls for those specific Nim types to do so
proc fromJson*(n: JsonNode, argName: string, result: var seq[byte]) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidHexData:
    raise newException(ValueError, invalidMsg(argName) & " as a hex data \"" & hexStr & "\"")
  result = hexToSeqByte(hexStr)

proc fromJson*(n: JsonNode, argName: string, result: var Hash256) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidHash256:
    raise newException(ValueError, invalidMsg(argName) & " as a Hash256 \"" & hexStr & "\"")
  hexToByteArray(hexStr, result.data)

proc fromJson*(n: JsonNode, argName: string, result: var JsonNode) =
  result = n
