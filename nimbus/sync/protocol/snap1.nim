# Nimbus - Ethereum Snap Protocol (SNAP), version 1
#
# Copyright (c) 2021 Status Research & Development GmbH
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
  std/options,
  chronicles,
  chronos,
  eth/[common, p2p, p2p/private/p2p_types],
  ./snap/snap_types,
  ../../constants

export
  snap_types

logScope:
  topics = "snap1"

const
  snapVersion* = 1
  prettySnapProtoName* = "[snap/" & $snapVersion & "]"

  # Pickeled tracer texts
  trSnapRecvReceived* =
    "<< " & prettySnapProtoName & " Received "
  trSnapRecvProtocolViolation* =
    "<< " & prettySnapProtoName & " Protocol violation, "
  trSnapRecvError* =
    "<< " & prettySnapProtoName & " Error "
  trSnapRecvTimeoutWaiting* =
    "<< " & prettySnapProtoName & " Timeout waiting "

  trSnapSendSending* =
    ">> " & prettySnapProtoName & " Sending "
  trSnapSendReplying* =
    ">> " & prettySnapProtoName & " Replying "


proc read(rlp: var Rlp, t: var SnapAccount, T: type Account): T =
  ## RLP mixin, decoding
  rlp.snapRead T

proc read(rlp: var Rlp; T: type SnapProofNodes): T =
  ## RLP mixin, decoding
  rlp.snapRead T

proc read(rlp: var Rlp; T: type SnapTriePaths): T =
  ## RLP mixin, decoding
  rlp.snapRead T

proc append(writer: var RlpWriter, t: SnapAccount, account: Account) =
  ## RLP mixin, encoding
  writer.snapAppend account

proc append(writer: var RlpWriter; spn: SnapProofNodes) =
  ## RLP mixin, encoding
  writer.snapAppend spn

proc append(writer: var RlpWriter; stn: SnapTriePaths) =
  ## RLP mixin, encoding
  writer.snapAppend stn

template handleHandlerError(x: untyped) =
  if x.isErr:
    raise newException(EthP2PError, x.error)

p2pProtocol snap1(version = snapVersion,
                  rlpxName = "snap",
                  peerState = SnapPeerState,
                  networkState = SnapWireBase,
                  useRequestIds = true):

  requestResponse:
    # User message 0x00: GetAccountRange.
    proc getAccountRange(
        peer: Peer;
        root: Hash256;
        origin: openArray[byte];
        limit: openArray[byte];
        replySizeMax: uint64;
          ) =
      trace trSnapRecvReceived & "GetAccountRange (0x00)", peer, root,
        nOrigin=origin.len, nLimit=limit.len, replySizeMax

      let
        ctx = peer.networkState()
        res = ctx.getAccountRange(
          root, origin, limit, replySizeMax)
      handleHandlerError(res)

      let
        (accounts, proof) = res.get
        # For logging only
        nAccounts = accounts.len
        nProof = proof.nodes.len

      if nAccounts == 0 and nProof == 0:
        trace trSnapSendReplying & "EMPTY AccountRange (0x01)", peer
      else:
        trace trSnapSendReplying & "AccountRange (0x01)", peer,
          nAccounts, nProof

      await response.send(accounts, proof)

    # User message 0x01: AccountRange.
    proc accountRange(
        peer: Peer;
        accounts: openArray[SnapAccount];
        proof: SnapProofNodes)


  requestResponse:
    # User message 0x02: GetStorageRanges.
    proc getStorageRanges(
        peer: Peer;
        root: Hash256;
        accounts: openArray[Hash256];
        origin: openArray[byte];
        limit: openArray[byte];
        replySizeMax: uint64;
          ) =
      trace trSnapRecvReceived & "GetStorageRanges (0x02)", peer, root,
        nAccounts=accounts.len, nOrigin=origin.len, nLimit=limit.len,
        replySizeMax

      let
        ctx = peer.networkState()
        res = ctx.getStorageRanges(
          root, accounts, origin, limit, replySizeMax)
      handleHandlerError(res)

      let
        (slots, proof) = res.get
        # For logging only
        nSlots = slots.len
        nProof = proof.nodes.len

      if nSlots == 0 and nProof == 0:
        trace trSnapSendReplying & "EMPTY StorageRanges (0x03)", peer
      else:
        trace trSnapSendReplying & "StorageRanges (0x03)", peer,
          nSlots, nProof

      await response.send(slots, proof)

    # User message 0x03: StorageRanges.
    # Note: See comments in this file for a list of Geth quirks to expect.
    proc storageRanges(
        peer: Peer;
        slotLists: openArray[seq[SnapStorage]];
        proof: SnapProofNodes)


  requestResponse:
    # User message 0x04: GetByteCodes.
    proc getByteCodes(
        peer: Peer;
        nodes: openArray[Hash256];
        replySizeMax: uint64;
          ) =
      trace trSnapRecvReceived & "GetByteCodes (0x04)", peer,
        nNodes=nodes.len, replySizeMax

      let
        ctx = peer.networkState()
        codes = ctx.getByteCodes(nodes, replySizeMax)

      handleHandlerError(codes)

      let
        # For logging only
        nCodes = codes.get.len

      if nCodes == 0:
        trace trSnapSendReplying & "EMPTY ByteCodes (0x05)", peer
      else:
        trace trSnapSendReplying & "ByteCodes (0x05)", peer, nCodes

      await response.send(codes.get)

    # User message 0x05: ByteCodes.
    proc byteCodes(
        peer: Peer;
        codes: openArray[Blob])


  requestResponse:
    # User message 0x06: GetTrieNodes.
    proc getTrieNodes(
        peer: Peer;
        root: Hash256;
        pathGroups: openArray[SnapTriePaths];
        replySizeMax: uint64;
          ) =
      trace trSnapRecvReceived & "GetTrieNodes (0x06)", peer, root,
        nPathGroups=pathGroups.len, replySizeMax

      let
        ctx = peer.networkState()
        nodes = ctx.getTrieNodes(root, pathGroups, replySizeMax)

      handleHandlerError(nodes)

      let
        # For logging only
        nNodes = nodes.get.len

      if nNodes == 0:
        trace trSnapSendReplying & "EMPTY TrieNodes (0x07)", peer
      else:
        trace trSnapSendReplying & "TrieNodes (0x07)", peer, nNodes

      await response.send(nodes.get)

    # User message 0x07: TrieNodes.
    proc trieNodes(
        peer: Peer;
        nodes: openArray[Blob])

# End
