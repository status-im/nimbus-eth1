# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[strutils, tables],
  stew/byteutils,
  stint,
  json_serialization,
  json_serialization/pkg/results,
  eth/common/eth_types_rlp,
  eth/common/keys,
  eth/common/blocks,
  ../../execution_chain/transaction,
  ../../execution_chain/common/chain_config

createJsonFlavor Fixture,
  automaticObjectSerialization = false,
  requireAllFields = false,
  omitOptionalFields = true, # Skip optional fields==none in Writer
  allowUnknownFields = true,
  skipNullFields = true      # Skip optional fields==null in Reader

AccessPair.useDefaultSerializationIn Fixture
Authorization.useDefaultSerializationIn Fixture

template wrapValueError(body: untyped) =
  try:
    body
  except ValueError as exc:
    r.raiseUnexpectedValue(exc.msg)

func parseHexOrInt[T](x: string): T {.raises: [ValueError].} =
  when T is UInt256:
    if ':' in x:
      high(UInt256)
    elif x.startsWith("0x"):
      UInt256.fromHex(x)
    else:
      parse(x, UInt256, 10)
  else:
    if x.startsWith("0x"):
      fromHex[T](x)
    else:
      parseInt(x).T

proc parsePaddedHex[T](r: var JsonReader[Fixture], val: var T)
       {.raises: [IOError, ValueError, JsonReaderError].} =
  var data = r.parseString()
  data.removePrefix("0x")
  const
    valLen = sizeof(T)
    hexLen = valLen*2
  if data.len < hexLen:
    data = repeat('0', hexLen - data.len) & data
  if data.len > hexLen:
    r.raiseUnexpectedValue("hex string is longer than expected: " & $hexLen & " get: " & $data.len)
  val = T(hexToByteArray(data, valLen))

proc readValue*(r: var JsonReader[Fixture], val: var Address)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    r.parsePaddedHex(val)

proc readValue*(r: var JsonReader[Fixture], val: var Bytes32)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    r.parsePaddedHex(val)

proc readValue*(r: var JsonReader[Fixture], val: var Hash32)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    r.parsePaddedHex(val)

proc readValue*(r: var JsonReader[Fixture], val: var UInt256)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    val = parseHexOrInt[UInt256](r.parseString())

proc readValue*(r: var JsonReader[Fixture], val: var (uint8 | uint64))
       {.raises: [IOError, JsonReaderError].} =
  let tok = r.tokKind
  if tok == JsonValueKind.Number:
    val = r.parseInt(typeof(val))
  else:
    wrapValueError:
      let x = parseHexOrInt[UInt256](r.parseString())
      type T = typeof(val)
      if x > T.high.u256:
        val = T.high
      else:
        val = x.truncate(T)

proc readValue*(r: var JsonReader[Fixture], val: var EthTime)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    val = parseHexOrInt[uint64](r.parseString()).EthTime

proc readValue*(r: var JsonReader[Fixture], val: var seq[byte])
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    val = hexToSeqByte(r.parseString())

proc readValue*(r: var JsonReader[Fixture], val: var GenesisStorage)
       {.raises: [IOError, SerializationError].} =
  r.parseObjectCustomKey:
    let slot = r.readValue(UInt256)
  do:
    val[slot] = r.readValue(UInt256)

proc readValue*(r: var JsonReader[Fixture], val: var GenesisAccount)
       {.raises: [IOError, SerializationError].} =
  var balanceParsed = false
  r.parseObject(key):
    case key
    of "code"   : r.readValue(val.code)
    of "nonce"  : r.readValue(val.nonce)
    of "balance":
      r.readValue(val.balance)
      balanceParsed = true
    of "storage": r.readValue(val.storage)
    else: discard r.readValue(JsonString)
  if not balanceParsed:
    r.raiseUnexpectedValue("GenesisAccount: balance required")

proc readValue*(r: var JsonReader[Fixture], val: var GenesisAlloc)
       {.raises: [IOError, SerializationError].} =
  r.parseObjectCustomKey:
    let address = r.readValue(Address)
  do:
    val[address] = r.readValue(GenesisAccount)

proc readValue*(r: var JsonReader[Fixture], val: var Table[uint64, Hash32])
       {.raises: [IOError, SerializationError].} =
  wrapValueError:
    r.parseObjectCustomKey:
      let number = parseHexOrInt[uint64](r.parseString())
    do:
      val[number] = r.readValue(Hash32)
