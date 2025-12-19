# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module implements Ethereum Snapshot Protocol version 1, `snap/1`.
## Specification:
##   `snap/1 <https://github.com/ethereum/devp2p/blob/master/caps/snap.md>`_

import
  pkg/[chronicles, chronos, eth/common],
  pkg/eth/common/transactions_rlp,
  ../../../core/pooled_txs_rlp,
  ../../../core/chain/forked_chain,
  ../../../networking/[p2p_types, rlpx],
  ../../../utils/utils,
  ./[snap_handler, snap_requester, snap_trace_config, snap_types]

logScope:
  topics = "snap1"

const
  prettySnapProtoName* = "[snap/1]"

  # Pickeled tracer texts
  trSnapRecvReceived* =
    "<< " & prettySnapProtoName & " Received"
  trSnapSendSending* =
    ">> " & prettySnapProtoName & " Sending"
  trSnapSendReplying* =
    ">> " & prettySnapProtoName & " Replying"

  trSnapSendSendingGetAccountRange* =
    trSnapSendSending & " getAccountRange (0x00)"
  trSnapSendReplyingAccountRange* =
    trSnapSendReplying & " accountRange (0x01)"
  trSnapRecvReceivedAccountRange* =
    trSnapRecvReceived & " accountRange"

  trSnapSendSendingGetStorageRanges* =
    trSnapSendSending & " getStorageRanges (0x02)"
  trSnapSendReplyingStorageRanges* =
    trSnapSendReplying & " storageRanges (0x03)"
  trSnapRecvReceivedStorageRanges* =
    trSnapRecvReceived & " storageRanges"

  trSnapSendSendingGetByteCodes* =
    trSnapSendSending & " getByteCodes (0x04)"
  trSnapSendReplyingByteCodes* =
    trSnapSendReplying & " byteCodes (0x05)"
  trSnapRecvReceivedByteCodes* =
    trSnapRecvReceived & " byteCodes"

  trSnapSendSendingGetTrieNodes* =
    trSnapSendSending & " getTrieNodes (0x06)"
  trSnapSendReplyingTrieNodes* =
    trSnapSendReplying & " trieNodes (0x07)"
  trSnapRecvReceivedTrieNodes* =
    trSnapRecvReceived & " trieNodes"

# ---------

proc getAccountRangeUserHandler(
    response: Responder;
    request: AccountRangeRequest;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  let
    peer = response.peer
    ctx = peer.networkState(snap1)

  when trSnapTraceGossipOk:
    trace trSnapSendSendingGetAccountRange, peer,
      rootHash      = request.rootHash.short,
      startingHash  = request.startingHash.short,
      limitHash     = request.limitHash.short,
      responseBytes = request.responseBytes

  # Get account range from application handler
  var data: AccountRangePacket
  block getData:
    data = ctx.getAccountRange(request).valueOr:
      trace trSnapSendReplyingAccountRange & "failed", peer
      break getData

    trace trSnapSendReplyingAccountRange, peer,
      nAccounts = data.accounts.len,
      nProof    = data.proof.len

  await response.accountRange(data.accounts, data.proof)


proc getStorageRangesUserHandler(
    response: Responder;
    request: StorageRangesRequest;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  let
    peer = response.peer
    ctx = peer.networkState(snap1)

  when trSnapTraceGossipOk:
    trace trSnapSendSendingGetStorageRanges, peer,
      rootHash       = request.rootHash.short,
      accountHashes  = (if request.accountHashes.len == 0: "n/a"
                        else: "[" & request.accountHashes[0].short & ",..]"),
      nAccountHashes = request.accountHashes.len,
      startingHash   = request.startingHash.short,
      limitHash      = request.limitHash.short,
      responseBytes  = request.responseBytes

  # Get storage ranges from application handler
  var data: StorageRangesPacket
  block getData:
    data = ctx.getStorageRanges(request).valueOr:
      trace trSnapSendReplyingStorageRanges & " failed", peer
      break getData

    trace trSnapSendReplyingStorageRanges, peer,
      nSlots = data.slots.len,
      nProof = data.proof.len

  await response.storageRanges(data.slots, data.proof)


proc getByteCodesUserHandler(
    response: Responder;
    request: ByteCodesRequest;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  let
    peer = response.peer
    ctx = peer.networkState(snap1)

  when trSnapTraceGossipOk:
    trace trSnapSendSendingGetByteCodes, peer,
      hashes = (if request.hashes.len == 0: "n/a"
                else: "[" & request.hashes[0].short & ",..]"),
      bytes  = request.bytes

  # Get byte codes from application handler
  var data: ByteCodesPacket
  block getData:
    data = ctx.getByteCodes(request).valueOr:
      trace trSnapSendReplyingByteCodes & " failed", peer
      break getData

    trace trSnapSendReplyingByteCodes, peer,
      nCodes = data.codes.len

  await response.byteCodes(data.codes)


proc getTrieNodesUserHandler(
    response: Responder;
    request: TrieNodesRequest;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  let
    peer = response.peer
    ctx = peer.networkState(snap1)

  when trSnapTraceGossipOk:
    trace trSnapSendSendingGetTrieNodes, peer,
      rootHash = request.rootHash.short,
      paths    = (if request.paths.len == 0: "n/a"
                  else: "[#" & $request.paths[0].len & ",..]"),
      nPaths   = request.paths.len,
      bytes    = request.bytes

  # Get trie nodes from application handler
  var data: TrieNodesPacket
  block getData:
    data = ctx.getTrieNodes(request).valueOr:
      trace trSnapSendReplyingTrieNodes & " failed", peer
      break getData

    trace trSnapSendReplyingTrieNodes, peer,
      nNodes = data.nodes.len

  await response.trieNodes(data.nodes)

# ---------

proc getAccountRangeThunk(
    peer: Peer;
    data: Rlp;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  snap1.rlpxWithPacketResponder(AccountRangeRequest, peer, data):
    await getAccountRangeUserHandler(response, packet)

proc accountRangeThunk(
    peer: Peer;
    data: Rlp;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  snap1.rlpxWithFutureHandler(AccountRangePacket, AccountRangeMsg,
    peer, data, [accounts, proof])

proc getStorageRangesThunk(
    peer: Peer;
    data: Rlp;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  snap1.rlpxWithPacketResponder(StorageRangesRequest, peer, data):
    await getStorageRangesUserHandler(response, packet)

proc storageRangesThunk(
    peer: Peer;
    data: Rlp;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  snap1.rlpxWithFutureHandler(StorageRangesPacket, StorageRangesMsg,
    peer, data, [slots, proof])

proc getByteCodesThunk(
    peer: Peer;
    data: Rlp;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  snap1.rlpxWithPacketResponder(ByteCodesRequest, peer, data):
    await getByteCodesUserHandler(response, packet)

proc byteCodesThunk(
    peer: Peer;
    data: Rlp;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  snap1.rlpxWithFutureHandler(ByteCodesPacket, ByteCodesMsg,
    peer, data, [codes])

proc getTrieNodesThunk(
    peer: Peer;
    data: Rlp;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  snap1.rlpxWithPacketResponder(TrieNodesRequest, peer, data):
    await getTrieNodesUserHandler(response, packet)

proc trieNodesThunk(
    peer: Peer;
    data: Rlp;
      ): Future[void]
      {.async: (raises: [CancelledError, EthP2PError]).} =
  snap1.rlpxWithFutureHandler(TrieNodesPacket, TrieNodesMsg,
    peer, data, [nodes])

# ---------

proc snap1Registration() =
  let protocol = snap1.initProtocol()

  registerMsg(protocol, GetAccountRangeMsg, "getAccountRange",
    getAccountRangeThunk, AccountRangeRequest)
  registerMsg(protocol, AccountRangeMsg, "accountRange",
    accountRangeThunk, AccountRangePacket)

  registerMsg(protocol, GetStorageRangesMsg, "getStorageRanges",
    getStorageRangesThunk, StorageRangesRequest)
  registerMsg(protocol, StorageRangesMsg, "storageRanges",
    storageRangesThunk, StorageRangesPacket)

  registerMsg(protocol, GetByteCodesMsg, "getByteCodes",
    getByteCodesThunk, ByteCodesRequest)
  registerMsg(protocol, ByteCodesMsg, "byteCodes",
    byteCodesThunk, ByteCodesPacket)

  registerMsg(protocol, GetTrieNodesMsg, "getTrieNodes",
    getTrieNodesThunk, TrieNodesRequest)
  registerMsg(protocol, TrieNodesMsg, "trieNodes",
    trieNodesThunk, TrieNodesPacket)

  registerProtocol(protocol)

snap1Registration()

# End
