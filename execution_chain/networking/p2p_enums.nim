# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

type
  ConnectionState* = enum
    None,
    Connecting,
    Connected,
    Disconnecting,
    Disconnected

  # Disconnect message reasons as specified:
  # https://github.com/ethereum/devp2p/blob/master/rlpx.md#disconnect-0x01
  # Receiving values that are too large or that are in the enum hole will
  # trigger `RlpTypeMismatch` error on deserialization.
  DisconnectionReason* = enum
    DisconnectRequested = 0x00,
    TcpError = 0x01,
    BreachOfProtocol = 0x02,
    UselessPeer = 0x03,
    TooManyPeers = 0x04,
    AlreadyConnected = 0x05,
    IncompatibleProtocolVersion = 0x06,
    NullNodeIdentityReceived = 0x07,
    ClientQuitting = 0x08,
    UnexpectedIdentity = 0x09,
    SelfConnection = 0x0A,
    PingTimeout = 0x0B,
    SubprotocolReason = 0x10
