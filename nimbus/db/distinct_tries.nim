# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# The point of this file is just to give a little more type-safety
# and clarity to our use of SecureHexaryTrie, by having distinct
# types for the big trie containing all the accounts and the little
# tries containing the storage for an individual account.
#
# It's nice to have all the accesses go through "getAccountBytes"
# rather than just "get" (which is hard to search for). Plus we
# may want to put in assertions to make sure that the nodes for
# the account are all present (in stateless mode), etc.

{.push raises: [].}

import
  std/[algorithm, sequtils, strutils, tables, options],
  eth/[common, rlp, trie/nibbles, trie/hexary],
  nimcrypto/[keccak, hash],
  chronicles,
  "."/[core_db, storage_types]

type
  DB = CoreDbRef
  AccountsTrie* = distinct CoreDbPhkRef
  StorageTrie* = distinct CoreDbPhkRef
  DistinctTrie* = AccountsTrie | StorageTrie

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

func toBase(t: DistinctTrie): CoreDbPhkRef =
  ## Note that `CoreDbPhkRef` is a distinct variant of `CoreDxPhkRef` for
  ## the legacy API.
  t.CoreDbPhkRef

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc toSvp*(sl: StorageTrie): seq[(UInt256,UInt256)] =
  ## Dump as slot id-value pair sequence
  let
    db = sl.toBase.parent
    save = db.trackLegaApi
  db.trackLegaApi = false
  defer: db.trackLegaApi = save
  let kvt = db.kvt
  var kvp: Table[UInt256,UInt256]
  try:
    for (slotHash,val) in sl.toBase.toMpt.pairs:
      if slotHash.len == 0:
        kvp[high UInt256] = high UInt256
      else:
        let slotRlp = kvt.get(slotHashToSlotKey(slotHash).toOpenArray)
        if slotRlp.len == 0:
          kvp[high UInt256] = high UInt256
        else:
          kvp[rlp.decode(slotRlp,UInt256)] = rlp.decode(val,UInt256)
  except CatchableError as e:
    raiseAssert "Ooops(" & $e.name & "): " & e.msg
  kvp.keys.toSeq.sorted.mapIt((it,kvp.getOrDefault(it,high UInt256)))

proc toStr*(w: seq[(UInt256,UInt256)]): string =
  "[" & w.mapIt("(" & it[0].toHex & "," & it[1].toHex & ")").join(", ") & "]"

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

# I don't understand why "borrow" doesn't work here. --Adam
proc rootHash*   (t: DistinctTrie): KeccakHash   = t.toBase.rootHash()
proc rootHashHex*(t: DistinctTrie): string       = $t.toBase.rootHash()
proc db*         (t: DistinctTrie): DB           = t.toBase.parent()
proc isPruning*  (t: DistinctTrie): bool         = t.toBase.isPruning()
proc mpt*        (t: DistinctTrie): CoreDbMptRef = t.toBase.toMpt()
func phk*        (t: DistinctTrie): CoreDbPhkRef = t.toBase

# ------------------------------------------------------------------------------
# Public functions: accounts trie
# ------------------------------------------------------------------------------

template initAccountsTrie*(db: DB, rootHash: KeccakHash, isPruning = true): AccountsTrie =
  AccountsTrie(db.phkPrune(rootHash, isPruning))

template initAccountsTrie*(db: DB, isPruning = true): AccountsTrie =
  AccountsTrie(db.phkPrune(isPruning))

proc getAccountBytes*(trie: AccountsTrie, address: EthAddress): seq[byte] =
  CoreDbPhkRef(trie).get(address)

proc maybeGetAccountBytes*(trie: AccountsTrie, address: EthAddress): Option[Blob]  {.gcsafe, raises: [RlpError].} =
  let phk = CoreDbPhkRef(trie)
  if phk.parent.isLegacy:
    phk.backend.toLegacy.SecureHexaryTrie.maybeGet(address)
  else:
    some(phk.get(address))

proc putAccountBytes*(trie: var AccountsTrie, address: EthAddress, value: openArray[byte]) =
  CoreDbPhkRef(trie).put(address, value)

proc delAccountBytes*(trie: var AccountsTrie, address: EthAddress) =
  CoreDbPhkRef(trie).del(address)

# ------------------------------------------------------------------------------
# Public functions: storage trie
# ------------------------------------------------------------------------------

proc initStorageTrie*(db: DB, rootHash: KeccakHash, isPruning = true): StorageTrie =
  StorageTrie(db.phkPrune(rootHash, isPruning))

template initStorageTrie*(db: DB, isPruning = true): StorageTrie =
  StorageTrie(db.phkPrune(isPruning))

template createTrieKeyFromSlot*(slot: UInt256): auto =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  slot.toBytesBE
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))
  # morally equivalent to toByteRange_Unnecessary but with different types

proc getSlotBytes*(trie: StorageTrie, slotAsKey: openArray[byte]): seq[byte] =
  CoreDbPhkRef(trie).get(slotAsKey)

proc maybeGetSlotBytes*(trie: StorageTrie, slotAsKey: openArray[byte]): Option[Blob] {.gcsafe, raises: [RlpError].} =
  let phk = CoreDbPhkRef(trie)
  if phk.parent.isLegacy:
    phk.backend.toLegacy.SecureHexaryTrie.maybeGet(slotAsKey)
  else:
    some(phk.get(slotAsKey))

proc putSlotBytes*(trie: var StorageTrie, slotAsKey: openArray[byte], value: openArray[byte]) =
  CoreDbPhkRef(trie).put(slotAsKey, value)

proc delSlotBytes*(trie: var StorageTrie, slotAsKey: openArray[byte]) =
  CoreDbPhkRef(trie).del(slotAsKey)

proc storageTrieForAccount*(trie: AccountsTrie, account: Account, isPruning = true): StorageTrie =
  # TODO: implement `prefix-db` to solve issue #228 permanently.
  # the `prefix-db` will automatically insert account address to the
  # underlying-db key without disturb how the trie works.
  # it will create virtual container for each account.
  # see nim-eth#9
  initStorageTrie(trie.db, account.storageRoot, isPruning)

# ------------------------------------------------------------------------------
# DistinctTrie - getBranch
# ------------------------------------------------------------------------------

type
  TrieNodeKey = object
    hash: KeccakHash
    usedBytes: uint8

template len(key: TrieNodeKey): int =
  key.usedBytes.int

template asDbKey(k: TrieNodeKey): untyped =
  doAssert k.usedBytes == 32
  k.hash.data

template extensionNodeKey(r: Rlp): auto =
  hexPrefixDecode r.listElem(0).toBytes

proc getLocalBytes(x: TrieNodeKey): seq[byte] =
  ## This proc should be used on nodes using the optimization
  ## of short values within the key.
  doAssert x.usedBytes < 32
  x.hash.data[0..<x.usedBytes]

proc dbGet(db: DB, data: openArray[byte]): seq[byte]
  {.gcsafe, raises: [].} =
  db.kvt.get(data)

template keyToLocalBytes(db: DB, k: TrieNodeKey): seq[byte] =
  if k.len < 32: k.getLocalBytes
  else: dbGet(db, k.asDbKey)

proc expectHash(r: Rlp): seq[byte] {.raises: [RlpError].} =
  result = r.toBytes
  if result.len != 32:
    raise newException(RlpTypeMismatch,
      "RLP expected to be a Keccak hash value, but has an incorrect length")

template getNode(db: DB, elem: Rlp): untyped =
  if elem.isList: @(elem.rawData)
  else: dbGet(db, elem.expectHash)

proc getBranchAux(
    db: DB, node: openArray[byte],
    fullPath: NibblesSeq,
    pathIndex: int,
    output: var seq[seq[byte]]) {.raises: [RlpError].} =
  var nodeRlp = rlpFromBytes node
  if not nodeRlp.hasData or nodeRlp.isEmpty: return

  let path = fullPath.slice(pathIndex)
  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    let sharedNibbles = sharedPrefixLen(path, k)
    if sharedNibbles == k.len:
      let value = nodeRlp.listElem(1)
      if not isLeaf:
        let nextLookup = getNode(db, value)
        output.add nextLookup
        getBranchAux(db, nextLookup, fullPath, pathIndex + sharedNibbles, output)
  of 17:
    if path.len != 0:
      var branch = nodeRlp.listElem(path[0].int)
      if not branch.isEmpty:
        let nextLookup = getNode(db, branch)
        output.add nextLookup
        getBranchAux(db, nextLookup, fullPath, pathIndex + 1, output)
  else:
    raise newException(RlpError, "node has an unexpected number of children")

proc getBranch*(self: DistinctTrie; key: openArray[byte]): seq[seq[byte]] {.raises: [RlpError].} =
  result = @[]
  var node = keyToLocalBytes(self.toBase.parent(),
      TrieNodeKey(hash: self.toBase.rootHash(), usedBytes: self.toBase.rootHash().data.len().uint8))
  result.add node
  getBranchAux(self.toBase.parent(), node, initNibbleRange(key), 0, result)