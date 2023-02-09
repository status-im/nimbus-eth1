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

## This module implements `snap/1`, the `Ethereum Snapshot Protocol (SNAP)
## <https://github.com/ethereum/devp2p/blob/master/caps/snap.md>`_.
##
## Modified `GetStorageRanges` (0x02) message syntax
## -------------------------------------------------
## As implementes here, the request message is encoded as
##
## `[reqID, rootHash, accountHashes, origin, limit, responseBytes]`
##
## It requests the storage slots of multiple accounts' storage tries. Since
## certain contracts have huge state, the method can also request storage
## slots from a single account, starting at a specific storage key hash.
## The intended purpose of this message is to fetch a large number of
## subsequent storage slots from a remote node and reconstruct a state
## subtrie locally.
##
## * `reqID`: Request ID to match up responses with
## * `rootHash`: 32 byte root hash of the account trie to serve
## * `accountHashes`: Array of 32 byte account hashes of the storage tries to serve
## * `origin`: Storage slot hash fragment of the first to retrieve (see below)
## * `limit`: Storage slot hash fragment after which to stop serving (see below)
## * `responseBytes`: 64 bit number soft limit at which to stop returning data
##
## Discussion of *Geth* `GetStorageRanges` behaviour
## ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
## - Parameters `origin` and `limit` may each be empty blobs, which mean "all
##   zeros" (0x00000...) or "no limit" (0xfffff...)  respectively.
##
##   (Blobs shorter than 32 bytes can also be given, and they are extended with
##   zero bytes; longer than 32 bytes can be given and are truncated, but this
##   is *Geth* being too accepting, and shouldn't be used.)
##
## - In the `slots` reply, the last account's storage list may be empty even if
##   that account has non-empty storage.
##
##   This happens when the bytes threshold is reached just after finishing
##   storage for the previous account, or when `origin` is greater than the
##   first account's last storage slot.  When either of these happens, `proof`
##   is non-empty.  In the case of `origin` zero or empty, the non-empty proof
##   only contains the left-side boundary proof, because it meets the condition
##   for omitting the right-side proof described in the next point.
##
## - In the `proof` reply, the right-side boundary proof is only included if
##   the last returned storage slot has non-zero path and `origin != 0`, or if
##   the result stops due to reaching the bytes threshold.
##
##   Because there's only one proof anyway if left-side and right-side are the
##   same path, this works out to mean the right-side proof is omitted in cases
##   where `origin == 0` and the result stops at a slot `>= limit` before
##   reaching the bytes threshold.
##
##   Although the specification doesn't say anything about `limit`, this is
##   against the spirit of the specification rule, which says the right-side
##   proof is always included if the last returned path differs from the
##   starting hash.
##
##   The omitted right-side proof can cause problems when using `limit`.
##   In other words, when doing range queries, or merging results from
##   pipelining where different `stateRoot` hashes are used as time progresses.
##   Workarounds:
##
##   * Fetch the proof using a second `GetStorageRanges` query with non-zero
##     `origin` (perhaps equal to `limit`; use `origin = 1` if `limit == 0`).
##
##   * Avoid the condition by using `origin >= 1` when using `limit`.
##
##   * Use trie node traversal (`snap` `GetTrieNodes`) to obtain the omitted proof.
##
## - When multiple accounts are requested with `origin > 0`, only one account's
##   storage is returned.  There is no point requesting multiple accounts with
##   `origin > 0`.  (It might be useful if it treated `origin` as applying to
##   only the first account, but it doesn't.)
##
## - When multiple accounts are requested with non-default `limit` and
##   `origin == 0`, and the first account result stops at a slot `>= limit`
##   before reaching the bytes threshold, storage for the other accounts in the
##   request are returned as well.  The other accounts are not limited by
##   `limit`, only the bytes threshold.  The right-side proof is omitted from
##   `proof` when this happens, because this is the same condition as described
##   earlier for omitting the right-side proof.  (It might be useful if it
##   treated `origin` as applying to only the first account and `limit` to only
##   the last account, but it doesn't.)
##
##
## Performance benefits
## --------------------
## `snap` is used for much higher performance transfer of the entire Ethereum
## execution state (accounts, storage, bytecode) compared with hexary trie
## traversal using the now obsolete `eth/66` `GetNodeData`.
##
## It improves both network and local storage performance.  The benefits are
## substantial, and summarised here:
##
## - `Ethereum Snapshot Protocol (SNAP) - Expected results
##    <https://github.com/ethereum/devp2p/blob/master/caps/snap.md>`_
## - `Geth v1.10.0 - Snap sync
##    <https://blog.ethereum.org/2021/03/03/geth-v1-10-0/#snap-sync>`_
##
## In the Snap sync model, local storage benefits require clients to adopt a
## different representation of Ethereum state than the trie storage that *Geth*
## (and most clients) traditionally used, and still do in archive mode,
##
## However, Nimbus's sync method obtains similar local storage benefits
## whichever network protocol is used.  Nimbus uses `snap` protocol because it
## is a more efficient network protocol.
##
## Distributed hash table (DHT) building block
## -------------------------------------------
## Although `snap` was designed for bootstrapping clients with the entire
## Ethereum state, it is well suited to fetching only a subset of path ranges.
## This may be useful for bootstrapping distributed hash tables (DHTs).
##
## Path range metadata benefits
## ----------------------------
## Because data is handled in path ranges, this allows a compact metadata
## representation of what data is stored locally and what isn't, compared with
## the size of a representation of partially completed trie traversal with
## `eth` `GetNodeData`.  Due to the smaller metadata, after aborting a partial
## sync and restarting, it is possible to resume quickly, without waiting for
## the very slow local database scan associated with older versions of *Geth*.
##
## However, Nimbus's sync method uses this principle as inspiration to
## obtain similar metadata benefits whichever network protocol is used.

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

proc read(rlp: var Rlp; t: var SnapProof; T: type Blob): T =
  ## RLP mixin, decoding
  rlp.snapRead T

proc append(writer: var RlpWriter, t: SnapAccount, account: Account) =
  ## RLP mixin, encoding
  writer.snapAppend account

proc append(writer: var RlpWriter; t: SnapProof; node: Blob) =
  ## RLP mixin, encoding
  writer.snapAppend node


p2pProtocol snap1(version = snapVersion,
                  rlpxName = "snap",
                  peerState = SnapPeerState,
                  networkState = SnapWireBase,
                  useRequestIds = true):

  requestResponse:
    # User message 0x00: GetAccountRange.
    # Note: `origin` and `limit` differs from the specification to match Geth.
    proc getAccountRange(
        peer: Peer;
        root: Hash256;
        origin: Hash256;
        limit: Hash256;
        replySizeMax: uint64;
          ) =
      trace trSnapRecvReceived & "GetAccountRange (0x00)", peer, root,
        origin, limit, replySizeMax

      let
        ctx = peer.networkState()
        (accounts, proof) = ctx.getAccountRange(
          root, origin, limit, replySizeMax)

        # For logging only
        nAccounts = accounts.len
        nProof = proof.len

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
        proof: openArray[SnapProof])


  requestResponse:
    # User message 0x02: GetStorageRanges.
    # Note: `origin` and `limit` differs from the specification to match Geth.
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
        (slots, proof) = ctx.getStorageRanges(
          root, accounts, origin, limit, replySizeMax)

        # For logging only
        nSlots = slots.len
        nProof = proof.len

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
        proof: openArray[SnapProof])


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

        # For logging only
        nCodes = codes.len

      if nCodes == 0:
        trace trSnapSendReplying & "EMPTY ByteCodes (0x05)", peer
      else:
        trace trSnapSendReplying & "ByteCodes (0x05)", peer, nCodes
        
      await response.send(@[])

    # User message 0x05: ByteCodes.
    proc byteCodes(
        peer: Peer;
        codes: openArray[Blob])


  requestResponse:
    # User message 0x06: GetTrieNodes.
    proc getTrieNodes(
        peer: Peer;
        root: Hash256;
        paths: openArray[seq[Blob]];
        replySizeMax: uint64;
          ) =
      trace trSnapRecvReceived & "GetTrieNodes (0x06)", peer, root,
        nPaths=paths.len, replySizeMax

      let
        ctx = peer.networkState()
        nodes = ctx.getTrieNodes(root, paths, replySizeMax)

        # For logging only
        nNodes = nodes.len

      if nNodes == 0:
        trace trSnapSendReplying & "EMPTY TrieNodes (0x07)", peer
      else:
        trace trSnapSendReplying & "TrieNodes (0x07)", peer, nNodes

      await response.send(nodes)

    # User message 0x07: TrieNodes.
    proc trieNodes(
        peer: Peer;
        nodes: openArray[Blob])

# End
