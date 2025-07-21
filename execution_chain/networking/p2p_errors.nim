# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  ./p2p_enums

type
  EthP2PError* = object of CatchableError

  UnsupportedProtocol* = object of EthP2PError
    # This is raised when you attempt to send a message from a particular
    # protocol to a peer that doesn't support the protocol.

  MalformedMessageError* = object of EthP2PError
  UnsupportedMessageError* = object of EthP2PError

  PeerDisconnected* = object of EthP2PError
    reason*: DisconnectionReason

  UselessPeerError* = object of EthP2PError

  P2PInternalError* = object of EthP2PError
