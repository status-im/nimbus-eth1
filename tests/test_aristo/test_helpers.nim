# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/sequtils,
  eth/common,
  rocksdb,
  ../../nimbus/db/aristo/[aristo_desc, aristo_merge],
  ../../nimbus/db/kvstore_rocksdb,
  ../../nimbus/sync/protocol/snap/snap_types,
  ../../nimbus/sync/snap/[constants, range_desc],
  ../test_sync_snap/test_types,
  ../replay/[pp, undump_accounts, undump_storages]

type
  ProofTrieData* = object
    root*: NodeKey
    id*: int
    proof*: seq[SnapProof]
    kvpLst*: seq[LeafKVP]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(w: UndumpAccounts; T: type ProofTrieData): T =
  T(root:   w.root.to(NodeKey),
    proof:  w.data.proof,
    kvpLst: w.data.accounts.mapIt(LeafKVP(
      pathTag: it.accKey.to(NodeTag),
      payload: PayloadRef(pType: BlobData, blob: it.accBlob))))

proc to(s: UndumpStorages; id: int; T: type seq[ProofTrieData]): T =
  for w in s.data.storages:
    result.add ProofTrieData(
      root:   w.account.storageRoot.to(NodeKey),
      id:     id,
      kvpLst: w.data.mapIt(LeafKVP(
        pathTag: it.slotHash.to(NodeTag),
        payload: PayloadRef(pType: BlobData, blob: it.slotData))))
  if 0 < result.len:
    result[^1].proof = s.data.proof

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# -----------------------

proc to*(sample: AccountsSample; T: type seq[UndumpAccounts]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath.value
  var root: Hash256
  for w in file.undumpNextAccount:
    let n = w.seenAccounts - 1
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

proc to*(sample: AccountsSample; T: type seq[UndumpStorages]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath.value
  var root: Hash256
  for w in file.undumpNextStorages:
    let n = w.seenAccounts - 1 # storages selector based on accounts
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

proc to*(w: seq[UndumpAccounts]; T: type seq[ProofTrieData]): T =
  w.mapIt(it.to(ProofTrieData))

proc to*(s: seq[UndumpStorages]; T: type seq[ProofTrieData]): T =
  for n,w in s:
    result &= w.to(n,seq[ProofTrieData])

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator walkAllDb*(rocky: RocksStoreRef): (int,Blob,Blob) =
  ## Walk over all key-value pairs of the database (`RocksDB` only.)
  let
    rop = rocky.store.readOptions
    rit = rocky.store.db.rocksdb_create_iterator(rop)
  defer:
    rit.rocksdb_iter_destroy()

  rit.rocksdb_iter_seek_to_first()
  var count = -1

  while rit.rocksdb_iter_valid() != 0:
    count .inc

    # Read key-value pair
    var
      kLen, vLen: csize_t
    let
      kData = rit.rocksdb_iter_key(addr kLen)
      vData = rit.rocksdb_iter_value(addr vLen)

    # Fetch data
    let
      key = if kData.isNil: EmptyBlob
            else: kData.toOpenArrayByte(0,int(kLen)-1).toSeq
      value = if vData.isNil: EmptyBlob
              else: vData.toOpenArrayByte(0,int(vLen)-1).toSeq

    yield (count, key, value)

    # Update Iterator (might overwrite kData/vdata)
    rit.rocksdb_iter_next()
    # End while

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
