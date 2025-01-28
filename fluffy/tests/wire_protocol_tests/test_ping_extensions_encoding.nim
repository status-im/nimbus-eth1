# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  stint,
  stew/byteutils,
  results,
  ../../network/wire/[messages, ping_extensions]

suite "Portal Wire Ping Extension Encodings - Type 0x00":
  test "SSZ encoded Ping request - with client info":
    let
      enr_seq = 1'u64
      data_radius = UInt256.high() - 1 # Full radius - 1
      client_info = "trin/v0.1.1-b61fdc5c/linux-x86_64/rustc1.81.0"
      capabilities = @[uint16 0, 1, 65535]

      payload = CapabilitiesPayload(
        client_info: ByteList[MAX_CLIENT_INFO_BYTE_LENGTH](client_info.toBytes()),
        data_radius: data_radius,
        capabilities: List[uint16, MAX_CAPABILITIES_LENGTH].init(capabilities),
      )
      customPayload = encodePayload(payload)
      ping = PingMessage(
        enrSeq: enr_seq, payload_type: CapabilitiesType, payload: customPayload
      )

    let encoded = encodeMessage(ping)
    check encoded.to0xHex ==
      "0x00010000000000000000000e00000028000000feffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff550000007472696e2f76302e312e312d62363166646335632f6c696e75782d7838365f36342f7275737463312e38312e3000000100ffff"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()
    let message = decoded.value()
    check:
      message.kind == MessageKind.ping
      message.ping.enrSeq == enr_seq
      message.ping.payload_type == CapabilitiesType
      message.ping.payload == customPayload

    let decodedPayload = decodeSsz(message.ping.payload.asSeq(), CapabilitiesPayload)
    check:
      decodedPayload.isOk()
      decodedPayload.value().client_info.asSeq() == client_info.toBytes()
      decodedPayload.value().data_radius == data_radius
      decodedPayload.value().capabilities.asSeq() == capabilities

  test "SSZ encoded Ping request - with empty client info":
    let
      enr_seq = 1'u64
      data_radius = UInt256.high() - 1 # Full radius - 1
      client_info = ""
      capabilities = @[uint16 0, 1, 65535]

      payload = CapabilitiesPayload(
        client_info: ByteList[MAX_CLIENT_INFO_BYTE_LENGTH](client_info.toBytes()),
        data_radius: data_radius,
        capabilities: List[uint16, MAX_CAPABILITIES_LENGTH].init(capabilities),
      )
      customPayload = encodePayload(payload)
      ping = PingMessage(
        enrSeq: enr_seq, payload_type: CapabilitiesType, payload: customPayload
      )

    let encoded = encodeMessage(ping)
    check encoded.to0xHex ==
      "0x00010000000000000000000e00000028000000feffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff2800000000000100ffff"
    let decoded = decodeMessage(encoded)
    check decoded.isOk()

  test "SSZ encoded Pong response - with client info":
    let
      enr_seq = 1'u64
      data_radius = UInt256.high() - 1 # Full radius - 1
      client_info = "trin/v0.1.1-b61fdc5c/linux-x86_64/rustc1.81.0"
      capabilities = @[uint16 0, 1, 65535]

      payload = CapabilitiesPayload(
        client_info: ByteList[MAX_CLIENT_INFO_BYTE_LENGTH](client_info.toBytes()),
        data_radius: data_radius,
        capabilities: List[uint16, MAX_CAPABILITIES_LENGTH].init(capabilities),
      )
      customPayload = encodePayload(payload)
      pong = PongMessage(
        enrSeq: enr_seq, payload_type: CapabilitiesType, payload: customPayload
      )

    let encoded = encodeMessage(pong)
    check encoded.to0xHex ==
      "0x01010000000000000000000e00000028000000feffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff550000007472696e2f76302e312e312d62363166646335632f6c696e75782d7838365f36342f7275737463312e38312e3000000100ffff"

  test "SSZ encoded Pong response - with empty client info":
    let
      enr_seq = 1'u64
      data_radius = UInt256.high() - 1 # Full radius - 1
      client_info = ""
      capabilities = @[uint16 0, 1, 65535]

      payload = CapabilitiesPayload(
        client_info: ByteList[MAX_CLIENT_INFO_BYTE_LENGTH](client_info.toBytes()),
        data_radius: data_radius,
        capabilities: List[uint16, MAX_CAPABILITIES_LENGTH].init(capabilities),
      )
      customPayload = encodePayload(payload)
      pong = PongMessage(
        enrSeq: enr_seq, payload_type: CapabilitiesType, payload: customPayload
      )

    let encoded = encodeMessage(pong)
    check encoded.to0xHex ==
      "0x01010000000000000000000e00000028000000feffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff2800000000000100ffff"

suite "Portal Wire Ping Extension Encodings - Type 0x01":
  test "SSZ encoded Ping request":
    let
      enr_seq = 1'u64
      data_radius = UInt256.high() - 1 # Full radius - 1

      payload = BasicRadiusPayload(data_radius: data_radius)
      customPayload = encodePayload(payload)
      ping = PingMessage(
        enrSeq: enr_seq, payload_type: BasicRadiusType, payload: customPayload
      )

    let encoded = encodeMessage(ping)
    check encoded.to0xHex ==
      "0x00010000000000000001000e000000feffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

  test "SSZ encoded Pong response":
    let
      enr_seq = 1'u64
      data_radius = UInt256.high() - 1 # Full radius - 1

      payload = BasicRadiusPayload(data_radius: data_radius)
      customPayload = encodePayload(payload)
      pong = PongMessage(
        enrSeq: enr_seq, payload_type: BasicRadiusType, payload: customPayload
      )

    let encoded = encodeMessage(pong)
    check encoded.to0xHex ==
      "0x01010000000000000001000e000000feffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

suite "Portal Wire Ping Extension Encodings - Type 0x02":
  test "SSZ encoded Ping request":
    let
      enr_seq = 1'u64
      data_radius = UInt256.high() - 1 # Full radius - 1
      ephemeral_header_count = 4242'u16

      payload = HistoryRadiusPayload(
        data_radius: data_radius, ephemeral_header_count: ephemeral_header_count
      )
      customPayload = encodePayload(payload)
      ping = PingMessage(
        enrSeq: enr_seq, payload_type: HistoryRadiusType, payload: customPayload
      )

    let encoded = encodeMessage(ping)
    check encoded.to0xHex ==
      "0x00010000000000000002000e000000feffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff9210"

  test "SSZ encoded Pong response":
    let
      enr_seq = 1'u64
      data_radius = UInt256.high() - 1 # Full radius - 1
      ephemeral_header_count = 4242'u16

      payload = HistoryRadiusPayload(
        data_radius: data_radius, ephemeral_header_count: ephemeral_header_count
      )
      customPayload = encodePayload(payload)
      pong = PongMessage(
        enrSeq: enr_seq, payload_type: HistoryRadiusType, payload: customPayload
      )

    let encoded = encodeMessage(pong)
    check encoded.to0xHex ==
      "0x01010000000000000002000e000000feffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff9210"

suite "Portal Wire Ping Extension Encodings - Type 0x03":
  test "SSZ encoded Pong response":
    let
      enr_seq = 1'u64
      error_code = 2'u16
      message = "hello world"

      payload = ErrorPayload(
        error_code: error_code,
        message: ByteList[MAX_ERROR_BYTE_LENGTH].init(message.toBytes()),
      )
      customPayload = encodePayload(payload)
      pong =
        PongMessage(enrSeq: enr_seq, payload_type: ErrorType, payload: customPayload)

    let encoded = encodeMessage(pong)
    check encoded.to0xHex ==
      "0x010100000000000000ffff0e00000002000600000068656c6c6f20776f726c64"
