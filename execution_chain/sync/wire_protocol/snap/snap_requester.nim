# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  pkg/[chronos, eth/common],
  ../../../networking/[p2p_types, rlpx],
  ./snap_types

const
  defaultTimeout = chronos.seconds(10)

  GetAccountRangeMsg*  = 0'u64
  AccountRangeMsg*     = 1'u64
  GetStorageRangesMsg* = 2'u64
  StorageRangesMsg*    = 3'u64
  GetByteCodesMsg*     = 4'u64
  ByteCodesMsg*        = 5'u64
  GetTrieNodesMsg*     = 6'u64
  TrieNodesMsg*        = 7'u64

defineProtocol(PROTO = snap1,
               version = 1,
               rlpxName = "snap",
               PeerStateType = SnapPeerStateRef,
               NetworkStateType = SnapWireStateRef)


proc getAccountRange*(
    peer: Peer;
    req: AccountRangeRequest;
    timeout = defaultTimeout;
      ): Future[Opt[AccountRangePacket]]
      {.async: (raises: [CancelledError,EthP2PError], raw: true).} =
  snap1.rlpxSendRequest(peer, timeout, GetAccountRangeMsg,
    req.rootHash, req.startingHash, req.limitHash, req.responseBytes)

proc accountRange*(
    responder: Responder;
    accounts: openArray[SnapAccount];
    proof: seq[ProofNode];
      ): Future[void]
      {.async: (raises: [CancelledError,EthP2PError], raw: true).} =
  if proof.len == 0:
    snap1.rlpxSendMessage(responder, AccountRangeMsg, accounts)
  else:
    snap1.rlpxSendMessage(responder, AccountRangeMsg, accounts, proof)


proc getStorageRanges*(
    peer: Peer;
    req: StorageRangesRequest;
    timeout = defaultTimeout;
      ): Future[Opt[StorageRangesPacket]]
      {.async: (raises: [CancelledError,EthP2PError], raw: true).} =
  snap1.rlpxSendRequest(peer, timeout, GetStorageRangesMsg,
    req.rootHash, req.accountHashes, req.startingHash, req.limitHash,
    req.responseBytes)

proc storageRanges*(
    responder: Responder;
    slots: seq[seq[StorageItem]];
    proof: seq[ProofNode];
      ): Future[void]
      {.async: (raises: [CancelledError,EthP2PError], raw: true).} =
  if proof.len == 0:
    snap1.rlpxSendMessage(responder, StorageRangesMsg, slots)
  else:
    snap1.rlpxSendMessage(responder, StorageRangesMsg, slots, proof)


proc getByteCodes*(
    peer: Peer;
    req: ByteCodesRequest;
    timeout = defaultTimeout;
      ): Future[Opt[ByteCodesPacket]]
      {.async: (raises: [CancelledError,EthP2PError], raw: true).} =
  snap1.rlpxSendRequest(peer, timeout, GetByteCodesMsg,
    req.hashes, req.bytes)

proc byteCodes*(
    responder: Responder;
    codes: seq[CodeItem];
      ): Future[void]
      {.async: (raises: [CancelledError,EthP2PError], raw: true).} =
  snap1.rlpxSendMessage(responder, ByteCodesMsg, codes)


proc getTrieNodes*(
    peer: Peer;
    req: TrieNodesRequest;
    timeout = defaultTimeout;
      ): Future[Opt[TrieNodesPacket]]
      {.async: (raises: [CancelledError,EthP2PError], raw: true).} =
  snap1.rlpxSendRequest(peer, timeout, GetTrieNodesMsg,
    req.rootHash, req.paths, req.bytes)

proc trieNodes*(
    responder: Responder;
    nodes: seq[NodeItem];
      ): Future[void]
      {.async: (raises: [CancelledError,EthP2PError], raw: true).} =
    snap1.rlpxSendMessage(responder, TrieNodesMsg, nodes)

# End
