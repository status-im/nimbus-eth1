# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronos,
  eth/rlp,
  ./p2p_enums,
  ./p2p_errors

export
  p2p_enums, p2p_errors

const
  MAX_PROTOCOLS* = 5
   ## devp2p, eth68, eth69, eth70, snap1
   ## modify if you need more

type
  ##
  ## Quasy-private types. Use at your own risk.
  ##
  ## Both Peer and Network generic params are workaround to
  ## avoid circular import.
  ##
  ## Peer usually instantiated by PeerRef
  ## Network usually instantiated by EthereumNode

  ProtocolManager*[Peer, Network] = ref object
    len*: int
    protocols*: array[MAX_PROTOCOLS, ProtocolInfoRef[Peer, Network]]

  Capability* = object
    name*: string
    version*: uint64

  ProtocolInfoRef*[Peer, Network] = ref object
    capability*: Capability
    messages*: seq[MessageInfoRef[Peer]]
    index*: int # the position of the protocol in the
                # ordered list of supported protocols

    # Private fields:
    peerStateInitializer*: PeerStateInitializer[Peer]
    networkStateInitializer*: NetworkStateInitializer[Network]

    onPeerConnected*: OnPeerConnectedHandler[Peer]
    onPeerDisconnected*: OnPeerDisconnectedHandler[Peer]

  MessageInfoRef*[Peer] = ref object
    id*: uint64 # this is a `msgId` (as opposed to a `reqId`)
    name*: string

    # Private fields:
    thunk*: ThunkProc[Peer]
    printer*: MessageContentPrinter
    requestResolver*: RequestResolver
    nextMsgResolver*: NextMsgResolver
    failResolver*: FailResolver

  ThunkProc*[Peer] = proc(x: Peer, data: Rlp): Future[void]
    {.async: (raises: [CancelledError, EthP2PError]).}

  MessageContentPrinter* = proc(msg: pointer): string
    {.gcsafe, raises: [].}

  RequestResolver* = proc(msg: pointer, future: FutureBase)
    {.gcsafe, raises: [].}

  NextMsgResolver* = proc(msgData: Rlp, future: FutureBase)
    {.gcsafe, raises: [RlpError].}

  FailResolver* = proc(reason: DisconnectionReason, future: FutureBase)
    {.gcsafe, raises: [].}

  PeerStateInitializer*[Peer] = proc(peer: Peer): RootRef
    {.gcsafe, raises: [].}

  NetworkStateInitializer*[Network] = proc(network: Network): RootRef
    {.gcsafe, raises: [].}

  OnPeerConnectedHandler*[Peer] = proc(peer: Peer): Future[void]
    {.async: (raises: [CancelledError, EthP2PError]).}

  OnPeerDisconnectedHandler*[Peer] = proc(peer: Peer, reason: DisconnectionReason):
    Future[void] {.async: (raises: []).}

func `$`*(v: Capability): string = v.name & "/" & $v.version

func setEventHandlers*[Peer, Network](
    p: ProtocolInfoRef[Peer, Network],
    onPeerConnected: OnPeerConnectedHandler[Peer],
    onPeerDisconnected: OnPeerDisconnectedHandler[Peer],
) =
  p.onPeerConnected = onPeerConnected
  p.onPeerDisconnected = onPeerDisconnected
