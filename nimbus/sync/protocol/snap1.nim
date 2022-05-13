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
## Modifications for *Geth* compatibility
## --------------------------------------
##
## `GetAccountRange` and `GetStorageRanges` take parameters `origin` and
## `limit`, instead of a single `startingHash` parameter in the
## specification. The parameters `origin` and `limit` are 256-bit paths
## representing the starting hash and ending trie path, both inclusive.
##
## The `snap/1` specification doesn't match reality. If the specification is
## strictly followed omitting `limit`, *Geth 1.10* disconnects immediately so
## this implementation strives to meet the *Geth* behaviour.
##
## Results from either call may include one item with path `>= limit`. *Geth*
## fetches data from its internal database until it reaches this condition or
## the bytes threshold, then replies with what it fetched.  Usually there is
## no item at the exact path `limit`, so there is one after.
##
##
## Modified `GetStorageRanges` (0x02) message syntax
## ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
##
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
##
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
##   * Use trie node traversal (`snap` `GetTrieNodes` or `eth` `GetNodeData`)
##     to obtain the omitted proof.
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
## Modified `GetAccountRange` (0x00) packet syntax
## ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
##
## As implementes here, the request message is encoded as
##
## `[reqID, rootHash, origin, limit, responseBytes]`
##
## It requests an unknown number of accounts from a given account trie, starting
## at the specified account hash and capped by the maximum allowed response
## size in bytes. The intended purpose of this message is to fetch a large
## number of subsequent accounts from a remote node and reconstruct a state
## subtrie locally.
##
## The `GetAccountRange` parameters `origin` and `limit` must be 32 byte
## blobs. There is no reason why empty limit is not allowed here when it is
## allowed for `GetStorageRanges`, it just isn't.
##
## * `reqID`: Request ID to match up responses with
## * `rootHash`: Root hash of the account trie to serve
## * `origin`: 32 byte storage slot hash of the first to retrieve
## * `limit`: 32 byte storage slot hash fragment after which to stop serving
## * `responseBytes`: 64 bit number soft limit at which to stop returning data
##
##
## Performance benefits
## --------------------
##
## `snap` is used for much higher performance transfer of the entire Ethereum
## execution state (accounts, storage, bytecode) compared with hexary trie
## traversal using `eth` `GetNodeData`.
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
## Remote state and Beam sync benefits
## -----------------------------------
##
## `snap` was not intended for Beam sync, or "remote state on demand", used by
## transactions executing locally that fetch state from the network instead of
## local storage.
##
## Even so, as a lucky accident `snap` allows individual states to be fetched
## in fewer network round trips than `eth`.  Often a single round trip,
## compared with about 10 round trips per account query over `eth`.  This is
## because `eth` `GetNodeData` requires a trie traversal chasing hashes
## sequentially, while `snap` `GetTrieNode` trie traversal can be done with
## predictable paths.
##
## Therefore `snap` can be used to accelerate remote states and Beam sync.
##
## Distributed hash table (DHT) building block
## -------------------------------------------
##
## Although `snap` was designed for bootstrapping clients with the entire
## Ethereum state, it is well suited to fetching only a subset of path ranges.
## This may be useful for bootstrapping distributed hash tables (DHTs).
##
## Path range metadata benefits
## ----------------------------
##
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
  eth/[common/eth_types, rlp, p2p],
  eth/p2p/[rlpx, private/p2p_types],
  nimcrypto/hash,
  stew/byteutils,
  stint,
  ".."/[sync_types, snap/types, trace_helper],
  ../../constants,
  ./pickeled_snap_tracers

type
  SnapAccount* = object
    accHash*: LeafPath
    accBody* {.rlpCustomSerialization.}: Account

  SnapAccountProof* = seq[Blob]

  SnapStorage* = object
    slotHash*: LeafPath
    slotData*: Blob

  SnapStorageProof* = seq[Blob]

const
  snapVersion* = 1
  prettySnapProtoName* = "[snap/" & $snapVersion & "]"

# The `snap` protocol represents `Account` differently from the regular RLP
# serialisation used in `eth` protocol as well as the canonical Merkle hash
# over all accounts.  In `snap`, empty storage hash and empty code hash are
# each represented by an RLP zero-length string instead of the full hash.  This
# avoids transmitting these hashes in about 90% of accounts.  We need to
# recognise or set these hashes in `Account` when serialising RLP for `snap`.

proc read(rlp: var Rlp, t: var SnapAccount, _: type Account): Account =
  ## RLP decoding for `SnapAccount`, which contains a path and account.
  ## The snap representation of the account differs from `Account` RLP.
  ## Empty storage hash and empty code hash are each represented by an
  ## RLP zero-length string instead of the full hash.
  rlp.tryEnterList()
  result.nonce = rlp.read(typeof(result.nonce))
  result.balance = rlp.read(typeof(result.balance))

  if rlp.blobLen != 0 or not rlp.isBlob:
    result.storageRoot = rlp.read(typeof(result.storageRoot))
    if result.storageRoot == BLANK_ROOT_HASH:
      raise newException(RlpTypeMismatch,
        "BLANK_ROOT_HASH not encoded as empty string in Snap protocol"
      )
  else:
    rlp.skipElem()
    result.storageRoot = BLANK_ROOT_HASH

  if rlp.blobLen != 0 or not rlp.isBlob:
    result.codeHash = rlp.read(typeof(result.codeHash))
    if result.codeHash == EMPTY_SHA3:
      raise newException(RlpTypeMismatch,
        "EMPTY_SHA3 not encoded as empty string in Snap protocol")
  else:
    rlp.skipElem()
    result.codeHash = EMPTY_SHA3

proc append(rlpWriter: var RlpWriter, t: SnapAccount, account: Account) =
  ## RLP encoding for `SnapAccount`, which contains a path and account.
  ## The snap representation of the account differs from `Account` RLP.
  ## Empty storage hash and empty code hash are each represented by an
  ## RLP zero-length string instead of the full hash.
  rlpWriter.append(account.nonce)
  rlpWriter.append(account.balance)

  if account.storageRoot == BLANK_ROOT_HASH:
    rlpWriter.append("")
  else:
    rlpWriter.append(account.storageRoot)

  if account.codeHash == EMPTY_SHA3:
    rlpWriter.append("")
  else:
    rlpWriter.append(account.codeHash)

# RLP serialisation for `LeafPath`.

template read(rlp: var Rlp, _: type LeafPath): LeafPath =
  rlp.read(array[sizeof(LeafPath().toBytes), byte]).toLeafPath

template append(rlpWriter: var RlpWriter, leafPath: LeafPath) =
  rlpWriter.append(leafPath.toBytes)


p2pProtocol snap1(version = 1,
                  rlpxName = "snap",
                  useRequestIds = true):

  requestResponse:
    # User message 0x00: GetAccountRange.
    # Note: `origin` and `limit` differs from the specification to match Geth.
    proc getAccountRange(peer: Peer, rootHash: TrieHash,
                         # Next line differs from spec to match Geth.
                         origin: LeafPath, limit: LeafPath,
                         responseBytes: uint64) =
      traceReceived "GetAccountRange (0x00)", peer,
        accountRange=pathRange(origin, limit),
        stateRoot=($rootHash), responseBytes

      traceReplying "EMPTY AccountRange (0x01)", peer, sent=0
      await response.send(@[], @[])

    # User message 0x01: AccountRange.
    proc accountRange(peer: Peer, accounts: seq[SnapAccount],
                      proof: SnapAccountProof)

  requestResponse:
    # User message 0x02: GetStorageRanges.
    # Note: `origin` and `limit` differs from the specification to match Geth.
    proc getStorageRanges(peer: Peer, rootHash: TrieHash,
                          accounts: openArray[LeafPath],
                          # Next line differs from spec to match Geth.
                          origin: openArray[byte], limit: openArray[byte],
                          responseBytes: uint64) =
      if tracePackets:
        var definiteFullRange = ((origin.len == 32 or origin.len == 0) and
                                 (limit.len == 32 or limit.len == 0))
        if definiteFullRange:
          for i in 0 ..< origin.len:
            if origin[i] != 0x00:
              definiteFullRange = false
              break
        if definiteFullRange:
          for i in 0 ..< limit.len:
            if limit[i] != 0xff:
              definiteFullRange = false
              break

        template describe(value: openArray[byte]): string =
          if value.len == 0: "(empty)"
          elif value.len == 32: value.toHex
          else: "(non-standard-len=" & $value.len & ')' & value.toHex

        if definiteFullRange:
          # Fetching storage for multiple accounts.
          traceReceived "GetStorageRanges/A (0x02)", peer,
            accountPaths=accounts.len,
            stateRoot=($rootHash), responseBytes
        elif accounts.len == 1:
          # Fetching partial storage for one account, aka. "large contract".
          traceReceived "GetStorageRanges/S (0x02)", peer,
            accountPaths=1,
            storageRange=(describe(origin) & '-' & describe(limit)),
            stateRoot=($rootHash), responseBytes
        else:
          # This branch is separated because these shouldn't occur.  It's not
          # really specified what happens when there are multiple accounts and
          # non-default path range.
          traceReceived "GetStorageRanges/AS?? (0x02)", peer,
            accountPaths=accounts.len,
            storageRange=(describe(origin) & '-' & describe(limit)),
            stateRoot=($rootHash), responseBytes

      traceReplying "EMPTY StorageRanges (0x03)", peer, sent=0
      await response.send(@[], @[])

    # User message 0x03: StorageRanges.
    # Note: See comments in this file for a list of Geth quirks to expect.
    proc storageRange(peer: Peer, slots: openArray[seq[SnapStorage]],
                      proof: SnapStorageProof)

  # User message 0x04: GetByteCodes.
  requestResponse:
    proc getByteCodes(peer: Peer, hashes: openArray[NodeHash],
                      responseBytes: uint64) =
      traceReceived "GetByteCodes (0x04)", peer,
        hashes=hashes.len, responseBytes

      traceReplying "EMPTY ByteCodes (0x05)", peer, sent=0
      await response.send(@[])

    # User message 0x05: ByteCodes.
    proc byteCodes(peer: Peer, codes: openArray[Blob])

  # User message 0x06: GetTrieNodes.
  requestResponse:
    proc getTrieNodes(peer: Peer, rootHash: TrieHash,
                      paths: openArray[InteriorPath], responseBytes: uint64) =
      traceReceived "GetTrieNodes (0x06)", peer,
        nodePaths=paths.len, stateRoot=($rootHash), responseBytes

      traceReplying "EMPTY TrieNodes (0x07)", peer, sent=0
      await response.send(@[])

    # User message 0x07: TrieNodes.
    proc trieNodes(peer: Peer, nodes: openArray[Blob])
