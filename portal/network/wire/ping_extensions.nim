# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import ssz_serialization

const
  # Extension types
  CapabilitiesType* = 0'u16
  BasicRadiusType* = 1'u16
  HistoryRadiusType* = 2'u16
  ErrorType* = 65535'u16

  # Limits
  MAX_CLIENT_INFO_BYTE_LENGTH* = 200
  MAX_CAPABILITIES_LENGTH* = 400
  MAX_ERROR_BYTE_LENGTH* = 300

# Different ping extension payloads, TODO: could be moved to each their own file?
type
  CapabilitiesPayload* = object
    client_info*: ByteList[MAX_CLIENT_INFO_BYTE_LENGTH]
    data_radius*: UInt256
    capabilities*: List[uint16, MAX_CAPABILITIES_LENGTH]

  BasicRadiusPayload* = object
    data_radius*: UInt256

  HistoryRadiusPayload* = object
    data_radius*: UInt256
    ephemeral_header_count*: uint16

  ErrorPayload* = object
    error_code*: uint16
    message*: ByteList[MAX_ERROR_BYTE_LENGTH]

  CustomPayload* =
    CapabilitiesPayload | BasicRadiusPayload | HistoryRadiusPayload | ErrorPayload

  ErrorCode* = enum
    ExtensionNotSupported = 0
    RequestedDataNotFound = 1
    FailedToDecodePayload = 2
    SystemError = 3

func encodePayload*(payload: CustomPayload): ByteList[1100] =
  ByteList[1100].init(SSZ.encode(payload))

func encodeErrorPayload*(code: ErrorCode): (uint16, ByteList[1100]) =
  (
    ErrorType,
    encodePayload(
      ErrorPayload(
        error_code: uint16(ord(code)),
        message: ByteList[MAX_ERROR_BYTE_LENGTH].init(@[]),
      )
    ),
  )
