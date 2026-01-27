# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/typetraits,
  pkg/[chronicles, eth/common],
  ../../../constants

logScope:
  topics = "snap-wire"

type
  SnapPeerStateRef* = ref object of RootRef
    ## Internal state

  SnapWireStateRef* = ref object of RootRef
    ## Internal state

  # ---------

  SnapDistinctBlobs* = ProofNode | CodeItem | AccountOrSlotPath | NodeItem

  ProofNode* = distinct seq[byte]
    ## Rlp coded node data, to be handled different from a generic `seq[byte]

  CodeItem* = distinct seq[byte]
    ## Ditto

  AccountOrSlotPath* = distinct seq[byte]
    ## Ditto

  NodeItem* = distinct seq[byte]
    ## Ditto


  SnapDistinctHashes* = SnapRootHash | SnapCodeHash

  SnapRootHash* = distinct Hash32
    ## Subject to optimised `RLP`, empty hash: `EMPTY_ROOT_HASH`

  SnapCodeHash* = distinct Hash32
    ## Subject to optimised `RLP`, empty hash: `EMPTY_SHA3`

  # ---------

  AccBody* = object
    ## Re-organised `Account` object, subject to optimised `RLP`
    nonce*: AccountNonce
    balance*: UInt256
    storageRoot*: SnapRootHash
    codeHash*: SnapCodeHash

  SnapAccount* = object
    accHash*: Hash32
    accBody*: AccBody

  AccountRangeRequest* = object
    rootHash*: Hash32
    startingHash*: Hash32
    limitHash*: Hash32
    responseBytes*: uint64

  AccountRangePacket* = object
    accounts*: seq[SnapAccount]
    proof*: seq[ProofNode]


  StorageRangesRequest* = object
    rootHash*: Hash32
    accountHashes*: seq[Hash32]
    startingHash*: Hash32
    limitHash*: Hash32
    responseBytes*: uint64

  StorageItem* = object
    slotHash*: Hash32
    slotData*: seq[byte]

  StorageRangesPacket* = object
    slots*: seq[seq[StorageItem]]
    proof*: seq[ProofNode]


  ByteCodesRequest* = object
    hashes*: seq[Hash32]
    bytes*: uint64

  ByteCodesPacket* = object
    codes*: seq[CodeItem]


  TrieNodesRequest* = object
    rootHash*: Hash32
    paths*: seq[seq[AccountOrSlotPath]]
    bytes*: uint64

  TrieNodesPacket* = object
    nodes*: seq[NodeItem]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc snapRd(r: var Rlp, T: type SnapRootHash): T {.gcsafe, raises: [RlpError]} =
  ## RLP mixin, decoding
  if r.isEmpty():
    r.skipElem()
    EMPTY_ROOT_HASH.T                       # optimised snap encoding
  else:
    r.read(Hash32).T

proc snapRd(r: var Rlp, T: type SnapCodeHash): T {.gcsafe, raises: [RlpError]} =
  ## RLP mixin, decoding
  if r.isEmpty():
    r.skipElem()
    EMPTY_SHA3.T                            # optimised snap encoding
  else:
    r.read(Hash32).T


proc snapApp(w: var RlpWriter, val: SnapRootHash) =
  if Hash32(val) == EMPTY_ROOT_HASH:
    w.startList 0                           # optimised snap encoding
  else:
    w.append Hash32(val)

proc snapApp(w: var RlpWriter, val: SnapCodeHash) =
  if Hash32(val) == EMPTY_SHA3:
    w.startList 0                           # optimised snap encoding
  else:
    w.append Hash32(val)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func `==`*(a,b: SnapDistinctBlobs|SnapDistinctHashes): bool =
  a.distinctBase == b.distinctBase

func isEmpty*(a: SnapRootHash): bool =
  Hash32(a) == EMPTY_ROOT_HASH or Hash32(a) == zeroHash32

func isEmpty*(a: SnapCodeHash): bool =
  Hash32(a) == EMPTY_SHA3 or Hash32(a) == zeroHash32

# ------------------------------------------------------------------------------
# Public serialisation helpers
# ------------------------------------------------------------------------------

proc read*(
    r: var Rlp;
    T: type SnapDistinctBlobs;
      ): T
      {.gcsafe, raises: [RlpError].} =
  ## RLP decoding for a sequence of some `distinct` type.
  r.read(seq[byte]).T

proc read*(r: var Rlp, T: type AccBody): T {.gcsafe, raises: [RlpError]} =
  r.tryEnterList()
  result.nonce = r.read(AccountNonce)
  result.balance = r.read(UInt256)
  result.storageRoot = r.snapRd(SnapRootHash)
  result.codeHash = r.snapRd(SnapCodeHash)


proc append*(w: var RlpWriter; val: SnapDistinctBlobs) =
  ## RLP encoding for a sequence of some `distinct` type.
  w.append val.distinctBase

proc append*(w: var RlpWriter, val: AccBody) =
  w.startList 4
  w.append val.nonce
  w.append val.balance
  w.snapApp val.storageRoot
  w.snapApp val.codeHash

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
