# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[os, sequtils],
  eth/common,
  stew/endians2,
  ../../nimbus/db/aristo/[
    aristo_debug, aristo_desc, aristo_hike, aristo_layers,
    aristo_tx],
  ../replay/pp,
  "."/[undump_accounts, undump_desc, undump_storages, test_samples_xx]

type
  ProofTrieData* = object
    root*: Hash32
    id*: int
    proof*: seq[seq[byte]]
    kvpLst*: seq[LeafTiePayload]

const
  MaxFilterBulk = 150_000
    ## Policy setting for `schedStow()`

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toPfx(indent: int): string =
  "\n" & " ".repeat(indent)

func to(a: NodeKey; T: type UInt256): T =
  T.fromBytesBE ByteArray32(a)

func to(a: NodeKey; T: type PathID): T =
  a.to(UInt256).to(T)

# ------------------------------------------------------------------------------
# Public pretty printing
# ------------------------------------------------------------------------------

proc pp*(
    w: ProofTrieData;
    rootID: VertexID;
    db: AristoTxRef;
    indent = 4;
      ): string =
  let
    pfx = indent.toPfx
    rootLink = w.root.to(HashKey)
  result = "(" & rootLink.pp(db)
  result &= "," & $w.id & ",[" & $w.proof.len & "],"
  result &= pfx & " ["
  for n,kvp in w.kvpLst:
    if 0 < n:
      result &= "," & pfx & "  "
    result &= "(" & kvp.leafTie.pp(db) & "," & $kvp.payload.pType & ")"
  result &= "])"

proc pp*(w: ProofTrieData; indent = 4): string =
  var db = AristoTxRef()
  w.pp(VertexID(1), db, indent)

proc pp*(
    w: openArray[ProofTrieData];
    rootID: VertexID;
    db: AristoTxRef;
    indent = 4): string =
  let pfx = indent.toPfx
  "[" & w.mapIt(it.pp(rootID, db, indent + 1)).join("," & pfx & " ") & "]"

proc pp*(w: openArray[ProofTrieData]; indent = 4): string =
  let pfx = indent.toPfx
  "[" & w.mapIt(it.pp(indent + 1)).join("," & pfx & " ") & "]"

proc pp*(ltp: LeafTiePayload; db: AristoTxRef): string =
  "(" & ltp.leafTie.pp(db) & "," & ltp.payload.pp(db) & ")"

# ----------

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func `==`*[T: AristoError|VertexID](a: T, b: int): bool =
  a == T(b)

func `==`*(a: (VertexID,AristoError), b: (int,int)): bool =
  (a[0].int,a[1].int) == b

func `==`*(a: (VertexID,AristoError), b: (int,AristoError)): bool =
  (a[0].int,a[1]) == b

func `==`*(a: (int,AristoError), b: (int,int)): bool =
  (a[0],a[1].int) == b

func `==`*(a: (int,VertexID,AristoError), b: (int,int,int)): bool =
  (a[0], a[1].int, a[2].int) == b

func to*(a: Hash32; T: type UInt256): T =
  T.fromBytesBE a.data

func to*(a: Hash32; T: type PathID): T =
  a.to(UInt256).to(T)

func to*(a: HashKey; T: type UInt256): T =
  T.fromBytesBE 0u8.repeat(32 - a.len) & @(a.data)

proc to*(sample: AccountsSample; T: type seq[UndumpAccounts]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath.value
  var root: Hash32
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
  var root: Hash32
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

func to*(ua: seq[UndumpAccounts]; T: type seq[ProofTrieData]): T =
  var (rootKey, rootVid) = (default(Hash32), VertexID(0))
  for w in ua:
    let thisRoot = w.root
    if rootKey != thisRoot:
      (rootKey, rootVid) = (thisRoot, VertexID(rootVid.uint64 + 1))
    # TODO rewrite as account leaves
    # if 0 < w.data.accounts.len:
    #   result.add ProofTrieData(
    #     root:   rootKey,
    #     proof:  cast[seq[seq[byte]]](w.data.proof),
    #     kvpLst: w.data.accounts.mapIt(LeafTiePayload(
    #       leafTie: LeafTie(
    #         root:  rootVid,
    #         path:  it.accKey.to(PathID)),
    #       payload: LeafPayload(pType: RawData, rawBlob: it.accBlob))))

func to*(us: seq[UndumpStorages]; T: type seq[ProofTrieData]): T =
  var (rootKey, rootVid) = (default(Hash32), VertexID(0))
  for n,s in us:
    for w in s.data.storages:
      let thisRoot = w.account.storageRoot
      if rootKey != thisRoot:
        (rootKey, rootVid) = (thisRoot, VertexID(rootVid.uint64 + 1))
      # TODO rewrite as account leaves

      # if 0 < w.data.len:
      #   result.add ProofTrieData(
      #     root:   thisRoot,
      #     id:     n + 1,
      #     kvpLst: w.data.mapIt(LeafTiePayload(
      #       leafTie: LeafTie(
      #         root:  rootVid,
      #         path:  it.slotHash.to(PathID)),
      #       payload: LeafPayload(pType: RawData, rawBlob: it.slotData))))
    if 0 < result.len:
      result[^1].proof = cast[seq[seq[byte]]](s.data.proof)

func mapRootVid*(
    a: openArray[LeafTiePayload];
    toVid: VertexID;
      ): seq[LeafTiePayload] =
  a.mapIt(LeafTiePayload(
    leafTie: LeafTie(root: toVid, path: it.leafTie.path),
    payload: it.payload))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc schedStow*(
    db: AristoDbRef;                  # Database
      ): Result[void,AristoError] =
  ## Context based scheduled persistent/non-persistent storage.
  db.persist()

# ------------------

proc mergeList*(
    db: AristoDbRef;                   # Database, top layer
    leafs: openArray[LeafTiePayload];  # Leaf items to add to the database
    noisy = false;
      ): tuple[merged: int, dups: int, error: AristoError] =
  ## Variant of `merge()` for leaf lists.
  var (merged, dups) = (0, 0)
  for n,w in leafs:
    noisy.say "*** mergeList",
      " n=", n, "/", leafs.len
    # TODO refactor to not use generic data
    # let rc = db.mergeGenericData w
    # noisy.say "*** mergeList",
    #   " n=", n, "/", leafs.len,
    #   " rc=", (if rc.isOk: "ok" else: $rc.error),
    #   "\n    -------------\n"
    # if rc.isErr:
    #   return (n,dups,rc.error)
    # elif rc.value:
    #   merged.inc
    # else:
    #   dups.inc

  (merged, dups, AristoError(0))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
