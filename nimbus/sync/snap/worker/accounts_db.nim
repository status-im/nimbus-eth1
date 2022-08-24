# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[algorithm, hashes, options, sequtils, sets, strutils, strformat,
       tables, times],
  chronos,
  eth/[common/eth_types, p2p, rlp],
  eth/trie/[db, nibbles, trie_defs],
  nimcrypto/keccak,
  stew/byteutils,
  stint,
  rocksdb,
  ../../../constants,
  ../../../db/[kvstore_rocksdb, select_backend],
  "../.."/[protocol, types],
  ../range_desc,
  ./db/[bulk_storage, hexary_defs, hexary_desc, hexary_import,
        hexary_interpolate, hexary_paths, rocky_bulk_load]

{.push raises: [Defect].}

logScope:
  topics = "snap-proof"

export
  HexaryDbError

type
  AccountsDbRef* = ref object
    db: TrieDatabaseRef              ## General database
    rocky: RocksStoreRef             ## Set if rocksdb is available

  AccountsDbSessionRef* = ref object
    keyMap: Table[RepairKey,uint]    ## For debugging only (will go away)
    base: AccountsDbRef              ## Back reference to common parameters
    peer: Peer                       ## For log messages
    rpDB: HexaryTreeDB               ## Repair database

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(h: Hash256; T: type NodeKey): T =
  h.data.T

proc convertTo(data: openArray[byte]; T: type Hash256): T =
  discard result.NodeHash.init(data) # error => zero

template elapsed(duration: times.Duration; code: untyped) =
  block:
    let start = getTime()
    block:
      code
    duration = getTime() - start

template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

template noRlpExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except RlpError:
    return err(RlpEncoding)
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

template noPpError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops (" & info & ") " & $e.name & ": " & e.msg

proc toKey(a: RepairKey; ps: AccountsDbSessionRef): uint =
  if not a.isZero:
    noPpError("pp(RepairKey)"):
      if not ps.keyMap.hasKey(a):
        ps.keyMap[a] = ps.keyMap.len.uint + 1
      result = ps.keyMap[a]

proc toKey(a: NodeKey; ps: AccountsDbSessionRef): uint =
  a.to(RepairKey).toKey(ps)

proc toKey(a: NodeTag; ps: AccountsDbSessionRef): uint =
  a.to(NodeKey).toKey(ps)


proc pp(a: NodeKey; ps: AccountsDbSessionRef): string =
  if a.isZero: "ø" else:"$" & $a.toKey(ps)

proc pp(a: RepairKey; ps: AccountsDbSessionRef): string =
  if a.isZero: "ø" elif a.isNodeKey: "$" & $a.toKey(ps) else: "¶" & $a.toKey(ps)

proc pp(a: NodeTag; ps: AccountsDbSessionRef): string =
  a.to(NodeKey).pp(ps)

# ---------

proc pp(a: Hash256; collapse = true): string =
  if not collapse:
    a.data.mapIt(it.toHex(2)).join.toLowerAscii
  elif a == emptyRlpHash:
    "emptyRlpHash"
  elif a == blankStringHash:
    "blankStringHash"
  else:
    a.data.mapIt(it.toHex(2)).join[56 .. 63].toLowerAscii

proc pp(q: openArray[byte]; noHash = false): string =
  if q.len == 32 and not noHash:
    var a: array[32,byte]
    for n in 0..31: a[n] = q[n]
    ($Hash256(data: a)).pp
  else:
    q.toSeq.mapIt(it.toHex(2)).join.toLowerAscii.pp(hex = true)

proc pp(a: Account): string =
  noPpError("pp(Account)"):
    result = &"({a.nonce},{a.balance},{a.storageRoot},{a.codeHash})"

proc pp(sa: SnapAccount): string =
  "(" & $sa.accHash & "," & sa.accBody.pp & ")"

proc pp(al: seq[SnapAccount]): string =
  result = "  @["
  noPpError("pp(seq[SnapAccount])"):
    for n,rec in al:
      result &= &"|    # <{n}>|    {rec.pp},"
  if 10 < result.len:
    result[^1] = ']'
  else:
    result &= "]"

proc pp(blobs: seq[Blob]): string =
  result = "  @["
  noPpError("pp(seq[Blob])"):
    for n,rec in blobs:
      result &= "|    # <" & $n & ">|    \"" & rec.pp & "\".hexToSeqByte,"
  if 10 < result.len:
    result[^1] = ']'
  else:
    result &= "]"

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type AccountsDbRef;
    db: TrieDatabaseRef
      ): T =
  ## Main object constructor
  T(db: db)

proc init*(
    T: type AccountsDbRef;
    db: ChainDb
      ): T =
  ## Variant of `init()` allowing bulk import on rocksdb backend
  result = T(db: db.trieDB, rocky: db.rocksStoreRef)
  if not result.rocky.bulkStorageClearRockyCacheFile():
    result.rocky = nil

proc init*(
    T: type AccountsDbSessionRef;
    pv: AccountsDbRef;
    root: Hash256;
    peer: Peer = nil
      ): T =
  ## Start a new session, do some actions an then discard the session
  ## descriptor (probably after commiting data.)
  let desc = AccountsDbSessionRef(
    base: pv,
    peer: peer,
    rpDB: HexaryTreeDB(
      rootKey: root.to(NodeKey)))

  # Debugging, might go away one time ...
  desc.rpDB.keyPp = proc(key: RepairKey): string = key.pp(desc)
  return desc

# ------------------------------------------------------------------------------
# Public functions, session related
# ------------------------------------------------------------------------------

proc merge*(
    ps: AccountsDbSessionRef;
    proof: SnapAccountProof
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Import account proof records (as received with the snap message
  ## `AccountRange`) into the hexary trie of the repair database. These hexary
  ## trie records can be extended to a full trie at a later stage and used for
  ## validating account data.
  try:
    for n,rlpRec in proof:
      let rc = ps.rpDB.hexaryImport(rlpRec)
      if rc.isErr:
        trace "merge(SnapAccountProof)", peer=ps.peer,
          proofs=ps.rpDB.tab.len, accounts=ps.rpDB.acc.len, error=rc.error
        return err(rc.error)
  except RlpError:
    return err(RlpEncoding)
  except Exception as e:
    raiseAssert "Ooops merge(SnapAccountProof) " & $e.name & ": " & e.msg

  ok()


proc merge*(
    ps: AccountsDbSessionRef;
    base: NodeTag;
    acc: seq[PackedAccount];
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Import account records (as received with the snap message `AccountRange`)
  ## into the accounts list of the repair database. The accounts, together
  ## with some hexary trie records for proof can be used for validating
  ## the argument account data.
  ##
  if acc.len != 0:
    let
      pathTag0 = acc[0].accHash.to(NodeTag)
      pathTagTop = acc[^1].accHash.to(NodeTag)
      saveLen = ps.rpDB.acc.len

      # For error logging
      (peer, proofs, accounts) = (ps.peer, ps.rpDB.tab.len, ps.rpDB.acc.len)

    var
      error = NothingSerious
      saveQ: seq[RLeafSpecs]
      prependOk = false
    if 0 < ps.rpDB.acc.len:
      if pathTagTop <= ps.rpDB.acc[0].pathTag:
        # Prepend `acc` argument before `ps.rpDB.acc`
        saveQ = ps.rpDB.acc
        prependOk = true

      # Append, verify that there is no overlap
      elif pathTag0 <= ps.rpDB.acc[^1].pathTag:
        return err(AccountRangesOverlap)

    block collectAccounts:
      # Verify lower bound
      if pathTag0 < base:
        error = HexaryDbError.AccountSmallerThanBase
        trace "merge(seq[PackedAccount])", peer, proofs, base, accounts, error
        break collectAccounts

      # Add base for the records (no payload). Note that the assumption
      # holds: `ps.rpDB.acc[^1].tag <= base`
      if base < pathTag0:
        ps.rpDB.acc.add RLeafSpecs(pathTag: base)

      # Check for the case that accounts are appended
      elif 0 < ps.rpDB.acc.len and pathTag0 <= ps.rpDB.acc[^1].pathTag:
        error = HexaryDbError.AccountsNotSrictlyIncreasing
        trace "merge(seq[PackedAccount])", peer, proofs, base, accounts, error
        break collectAccounts

      # Add first account
      ps.rpDB.acc.add RLeafSpecs(pathTag: pathTag0, payload: acc[0].accBlob)

      # Veify & add other accounts
      for n in 1 ..< acc.len:
        let nodeTag = acc[n].accHash.to(NodeTag)

        if nodeTag <= ps.rpDB.acc[^1].pathTag:
          # Recover accounts list and return error
          ps.rpDB.acc.setLen(saveLen)

          error = AccountsNotSrictlyIncreasing
          trace "merge(seq[PackedAccount])", peer, proofs, base, accounts, error
          break collectAccounts

        ps.rpDB.acc.add RLeafSpecs(pathTag: nodeTag, payload: acc[n].accBlob)

      # End block `collectAccounts`

    if prependOk:
      if error == NothingSerious:
        ps.rpDB.acc = ps.rpDB.acc & saveQ
      else:
        ps.rpDB.acc = saveQ

    if error != NothingSerious:
      return err(error)

  ok()

proc interpolate*(ps: AccountsDbSessionRef): Result[void,HexaryDbError] =
  ## Verifiy accounts by interpolating the collected accounts on the hexary
  ## trie of the repair database. If all accounts can be represented in the
  ## hexary trie, they are vonsidered validated.
  ##
  ## Note:
  ##   This function is temporary and proof-of-concept. For production purposes,
  ##   it must be replaced by the new facility of the upcoming re-factored
  ##   database layer.
  ##
  noKeyError("interpolate"):
    result = ps.rpDB.hexaryInterpolate()

proc dbImports*(ps: AccountsDbSessionRef): Result[void,HexaryDbError] =
  ## Experimental: try several db-import modes and record statistics
  noPpError("dbImports"):
    if  ps.base.rocky.isNil:
      let rc = ps.rpDB.bulkStorageHexaryNodesOnChainDb(ps.base.db)
      if rc.isErr: return rc
    else:
      let rc = ps.rpDB.bulkStorageHexaryNodesOnRockyDb(ps.base.rocky)
      if rc.isErr: return rc

  ok()

proc sortMerge*(base: openArray[NodeTag]): NodeTag =
  ## Helper for merging several `(NodeTag,seq[PackedAccount])` data sets
  ## so that there are no overlap which would be rejected by `merge()`.
  ##
  ## This function selects a `NodeTag` from a list.
  result = high(NodeTag)
  for w in base:
    if w < result:
      result = w

proc sortMerge*(acc: openArray[seq[PackedAccount]]): seq[PackedAccount] =
  ## Helper for merging several `(NodeTag,seq[PackedAccount])` data sets
  ## so that there are no overlap which would be rejected by `merge()`.
  ##
  ## This function flattens and sorts the argument account lists.
  noPpError("sortMergeAccounts"):
    var accounts: Table[NodeTag,PackedAccount]
    for accList in acc:
      for item in accList:
        accounts[item.accHash.to(NodeTag)] = item
    result = toSeq(accounts.keys).sorted(cmp).mapIt(accounts[it])

proc nHexaryRecords*(ps: AccountsDbSessionRef): int  =
  ## Number of hexary record entries in the session database.
  ps.rpDB.tab.len

proc nAccountRecords*(ps: AccountsDbSessionRef): int  =
  ## Number of account records in the session database. This number includes
  ## lower bound entries (which are not accoiunts, strictly speaking.)
  ps.rpDB.acc.len

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbBackendRocksDb*(pv: AccountsDbRef): bool =
  ## Returns `true` if rocksdb features are available
  not pv.rocky.isNil

proc dbBackendRocksDb*(ps: AccountsDbSessionRef): bool =
  ## Returns `true` if rocksdb features are available
  not ps.base.rocky.isNil

proc importAccounts*(
    pv: AccountsDbRef;
    peer: Peer,               ## for log messages
    root: Hash256;            ## state root
    base: NodeTag;            ## before or at first account entry in `data`
    data: PackedAccountRange; ## re-packed `snap/1 ` reply data
    storeData = false
      ): Result[void,HexaryDbError] =
  ## Validate and accounts and proofs (as received with the snap message
  ## `AccountRange`). This function combines the functionality of the `merge()`
  ## and the `interpolate()` functions.
  ##
  ## At a later stage, that function also will bulk-import the accounts into
  ## the block chain database
  ##
  ## Note that the `peer` argument is for log messages, only.
  let ps = AccountsDbSessionRef.init(pv, root, peer)
  try:
    block:
      let rc = ps.merge(data.proof)
      if rc.isErr:
        return err(rc.error)
    block:
      let rc = ps.merge(base, data.accounts)
      if rc.isErr:
        return err(rc.error)
  except RlpError:
    return err(RlpEncoding)

  block:
    # Note:
    #   `interpolate()` is a temporary proof-of-concept function. For
    #   production purposes, it must be replaced by the new facility of
    #   the upcoming re-factored database layer.
    let rc = ps.interpolate()
    if rc.isErr:
      return err(rc.error)

  if storeData:
    # Experimental
    let rc = ps.dbImports()
    if rc.isErr:
      return err(rc.error)

  trace "Accounts and proofs ok", peer, root=root.data.toHex,
    proof=data.proof.len, base, accounts=data.accounts.len
  ok()

# ------------------------------------------------------------------------------
# Debugging (and playing with the hexary database)
# ------------------------------------------------------------------------------

proc getChainDbAccount*(
    ps: AccountsDbSessionRef;
    accHash: Hash256
      ): Result[Account,HexaryDbError] =
  ## Fetch account via `BaseChainDB`
  noRlpExceptionOops("getChainDbAccount()"):
    let
      getFn: HexaryGetFn = proc(key: Blob): Blob = ps.base.db.get(key)
      leaf = accHash.to(NodeKey).hexaryPath(ps.rpDB.rootKey, getFn).leafData
    if 0 < leaf.len:
      let acc = rlp.decode(leaf,Account)
      return ok(acc)

  err(AccountNotFound)

proc nextChainDbKey*(
    ps: AccountsDbSessionRef;
    accHash: Hash256
      ): Result[Hash256,HexaryDbError] =
  ## Fetch the account path on the `BaseChainDB`, the one next to the
  ## argument account.
  noRlpExceptionOops("getChainDbAccount()"):
    let
      getFn: HexaryGetFn = proc(key: Blob): Blob = ps.base.db.get(key)
      path = accHash.to(NodeKey)
                    .hexaryPath(ps.rpDB.rootKey, getFn)
                    .next(getFn)
                    .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256))

  err(AccountNotFound)

proc prevChainDbKey*(
    ps: AccountsDbSessionRef;
    accHash: Hash256
      ): Result[Hash256,HexaryDbError] =
  ## Fetch the account path on the `BaseChainDB`, the one before to the
  ## argument account.
  noRlpExceptionOops("getChainDbAccount()"):
    let
      getFn: HexaryGetFn = proc(key: Blob): Blob = ps.base.db.get(key)
      path = accHash.to(NodeKey)
                    .hexaryPath(ps.rpDB.rootKey, getFn)
                    .prev(getFn)
                    .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256))

  err(AccountNotFound)

proc assignPrettyKeys*(ps: AccountsDbSessionRef) =
  ## Prepare foe pretty pringing/debugging. Run early enough this function
  ## sets the root key to `"$"`, for instance.
  noPpError("validate(1)"):
    # Make keys assigned in pretty order for printing
    var keysList = toSeq(ps.rpDB.tab.keys)
    let rootKey = ps.rpDB.rootKey.to(RepairKey)
    discard rootKey.toKey(ps)
    if ps.rpDB.tab.hasKey(rootKey):
      keysList = @[rootKey] & keysList
    for key in keysList:
      let node = ps.rpDB.tab[key]
      discard key.toKey(ps)
      case node.kind:
      of Branch: (for w in node.bLink: discard w.toKey(ps))
      of Extension: discard node.eLink.toKey(ps)
      of Leaf: discard

proc dumpPath*(ps: AccountsDbSessionRef; key: NodeTag): seq[string] =
  ## Pretty print helper compiling the path into the repair tree for the
  ## argument `key`.
  noKeyError("dumpPath"):
    let rPath = key.hexaryPath(ps.rpDB)
    result = rPath.path.mapIt(it.pp(ps.rpDB)) & @["(" & rPath.tail.pp & ")"]

proc dumpProofsDB*(ps: AccountsDbSessionRef): seq[string] =
  ## Dump the entries from the repair tree.
  noPpError("dumpRoot"):
    var accu = @[(0u, "($0" & "," & ps.rpDB.rootKey.pp(ps) & ")")]
    for key,node in ps.rpDB.tab.pairs:
      accu.add (key.toKey(ps), "(" & key.pp(ps) & "," & node.pp(ps.rpDB) & ")")
    proc cmpIt(x, y: (uint,string)): int =
      cmp(x[0],y[0])
    result = accu.sorted(cmpIt).mapIt(it[1])

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
