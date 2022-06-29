# Nimbus - Fetch account and storage states from peers by snapshot traversal
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[algorithm, hashes, options, sequtils, sets, strutils, strformat, tables],
  chronos,
  eth/[common/eth_types, p2p, rlp, trie/db],
  nimcrypto/keccak,
  stew/[byteutils, interval_set],
  stint,
  ../../../../db/storage_types,
  "../../.."/[protocol, types],
  ../../path_desc,
  ../worker_desc

{.push raises: [Defect].}

logScope:
  topics = "snap-proof"

const
  RowColumnParserDump = false
  NibbleFollowDump = false # true

type
  ProofError* = enum
    RlpEncoding
    RlpBlobExpected
    RlpNonEmptyBlobExpected
    RlpBranchLinkExpected
    RlpListExpected
    Rlp2Or17ListEntries
    RlpExtPathEncoding
    RlpLeafPathEncoding
    RlpRecTypeError
    ImpossibleKeyError
    RowUnreferenced
    AccountSmallerThanBase
    AccountsNotSrictlyIncreasing
    LastAccountProofFailed
    MissingMergeBeginDirective
    StateRootDiffers

  ProofRecType = enum
    Branch,
    Extension,
    Leaf

  StatusRec = object
    nAccounts: int
    nProofs: int

  AccountRec = ##\
    ## Account entry record
    distinct Account

  ProofRec = object
    ## Proofs entry record
    case kind: ProofRecType
    of Branch:
      vertex: array[16,NodeTag]
      value: Blob                 # name starts with a `v` as in vertex
    of Extension:
      extend: PathSegment
      follow: NodeTag
    of Leaf:
      path: PathSegment
      payload: Blob               # name starts with a `p` as in path

  ProofKvp = object
    key: NodeTag
    data: Option[ProofRec]

  ProofDb* = object
    keyMap: Table[NodeTag,uint]              ## For debugging only

    rootTag: NodeTag                         ## Current root node
    rootHash: TrieHash                       ## Root node as hash
    stat: StatusRec                          ## table statistics

    db: TrieDatabaseRef                      ## general database
    dbTx: DbTransaction                      ## Rollback state capture

    newAccs: seq[(NodeTag,NodeTag)]          ## New accounts group: (base,last)
    newProofs: seq[NodeTag]                  ## Newly added proofs records
    refPool: HashSet[NodeTag]                ## New proofs references recs

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template noRlpError(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg

proc read(rlp: var Rlp; T: type ProofRec): T =
  ## RLP mixin
  noRlpError("read(ProofRec)"):
    result.kind = rlp.read(typeof result.kind)
    rlp.tryEnterList()
    case result.kind:
    of Branch:
      result.vertex = rlp.read(typeof result.vertex)
      result.value = rlp.read(typeof result.value)
    of Extension:
      result.extend = rlp.dbRead(typeof result.extend)
      result.follow = rlp.read(typeof result.follow)
    of Leaf:
      result.path = rlp.dbRead(typeof result.path)
      result.payload = rlp.read(typeof result.payload)

proc append(writer: var RlpWriter; rec: ProofRec) =
  ## RLP mixin
  append(writer, rec.kind)
  startList(writer, 2)
  case rec.kind:
  of Branch:
    append(writer, rec.vertex)
    append(writer, rec.value)
  of Extension:
    dbAppend(writer, rec.extend)
    append(writer, rec.follow)
  of Leaf:
    dbAppend(writer, rec.path)
    append(writer, rec.payload)

proc to(w: TrieHash; T: type NodeTag): T =
  ## Syntactic sugar
  w.Hash256.to(T)

proc to(w: AccountRec; T: type Account): T =
  ## Syntactic sugar
  w.T

proc to(w: Account; T: type AccountRec): T =
  ## Syntactic sugar
  w.T


func nibble(a: array[32,byte]; inx: int): int =
  let byteInx = inx shr 1
  if byteInx < 32:
    if (inx and 1) == 0:
      result = (a[byteInx] shr 4).int
    else:
      result = (a[byteInx] and 15).int

proc clearJournal(pv: var ProofDb) =
  pv.newAccs.setLen(0)
  pv.newProofs.setLen(0)
  pv.refPool.clear

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

import
  ../../../../constants

template noPpError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

proc pp(s: string; hex = false): string =
  if hex:
    let n = (s.len + 1) div 2
    (if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. s.len-1]) &
      "[" & (if 0 < n: "#" & $n else: "") & "]"
  elif s.len <= 30:
    s
  else:
    (if (s.len and 1) == 0: s[0 ..< 8] else: "0" & s[0 ..< 7]) &
      "..(" & $s.len & ").." & s[s.len-16 ..< s.len]

proc pp(a: Hash256; collapse = true): string =
  if not collapse:
    a.data.mapIt(it.toHex(2)).join.toLowerAscii
  elif a == ZERO_HASH256:
    "ZERO_HASH256"
  elif a == BLANK_ROOT_HASH:
    "BLANK_ROOT_HASH"
  elif a == EMPTY_UNCLE_HASH:
    "EMPTY_UNCLE_HASH"
  elif a == EMPTY_SHA3:
    "EMPTY_SHA3"
  elif a == ZERO_HASH256:
    "ZERO_HASH256"
  else:
    a.data.mapIt(it.toHex(2)).join[56 .. 63].toLowerAscii

proc pp(a: NodeHash|TrieHash; collapse = true): string =
  a.Hash256.pp(collapse)

proc pp(a: NodeTag; collapse = true): string =
  a.to(Hash256).pp(collapse)

proc toKey(a: NodeTag; pv: var ProofDb): uint =
  noPpError("pp(NodeTag)"):
    if not pv.keyMap.hasKey(a):
      pv.keyMap[a] = pv.keyMap.len.uint + 1
    result = pv.keyMap[a]

proc pp(a: NodeTag; pv: var ProofDb): string =
  $a.toKey(pv)

proc pp(q: openArray[byte]; noHash = false): string =
  if q.len == 32 and not noHash:
    var a: array[32,byte]
    for n in 0..31: a[n] = q[n]
    ($Hash256(data: a)).pp
  else:
    q.toSeq.mapIt(it.toHex(2)).join.toLowerAscii.pp(hex = true)

proc pp(blob: Blob): string =
  blob.mapIt(it.toHex(2)).join

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

proc pp(hs: seq[NodeTag]; pv: var ProofDb): string =
 "<" & hs.mapIt(it.pp(pv)).join(",") & ">"

proc pp(hs: HashSet[NodeTag]; pv: var ProofDb): string =
  "{" & toSeq(hs.items).mapIt(it.toKey(pv)).sorted.mapIt($it).join(",") & "}"

proc pp(rec: ProofRec; pv: var ProofDb): string =
  noPpError("pp(ProofRec)"):
    case rec.kind:
    of Branch: result &=
      "b(" & rec.vertex.mapIt(it.pp(pv)).join(",") & "," &
        rec.value.pp.pp(true) & ")"
    of Leaf: result &=
      "l(" & ($rec.path).pp(true) & "," & rec.payload.pp.pp(true) & ")"
    of Extension: result &=
      "x(" & ($rec.extend).pp(true) & "," & rec.follow.pp(pv) & ")"

proc pp(rec: Option[ProofRec]; pv: var ProofDb): string =
  if rec.isSome:
    rec.get.pp(pv)
  else:
    "n/a"

proc pp(q: seq[ProofKvp]; pv: var ProofDb): string =
  result="@["
  for kvp in q:
    result &= "(" & kvp.key.pp(pv) & "," & kvp.data.pp(pv) & "),"
  if q.len == 0:
    result &= "]"
  else:
    result[^1] = ']'

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template mkProofKey(pv: ProofDb; tag: NodeTag): openArray[byte] =
  tag.to(Hash256).snapSyncProofKey.toOpenArray

proc getProofsRec(pv: ProofDb; tag: NodeTag): Result[ProofRec,void] =
  let recData = pv.db.get(pv.mkProofKey(tag))
  if 0 < recData.len:
    return ok(recData.decode(ProofRec))
  err()

proc hasProofsRec(pv: ProofDb; tag: NodeTag): bool =
  pv.db.contains(pv.mkProofKey(tag))

proc collectRefs(pv: var ProofDb; rec: ProofRec) =
  case rec.kind:
  of Branch:
    for v in rec.vertex:
      pv.refPool.incl v
  of Extension:
    pv.refPool.incl rec.follow
  of Leaf:
    discard

proc collectRefs(pv: var ProofDb; tag: NodeTag) =
  let rc = pv.getProofsRec(tag)
  if rc.isOk:
    pv.collectRefs(rc.value)

proc addProofsRec(pv: var ProofDb; tag: NodeTag; rec: ProofRec) =
  #debug "addProofsRec", size=pv.nProofs, tag=tag.pp(pv), rec=rec.pp(pv)
  if not pv.hasProofsRec(tag):
    pv.db.put(pv.mkProofKey(tag), rlp.encode(rec))
    pv.stat.nProofs.inc
    pv.newProofs.add tag # to be committed
  # Always add references, the rec might have been added earlier outside
  # the current transaction.
  pv.collectRefs(rec)

# -----------

template mkAccKey(pv: ProofDb; tag: NodeTag): openArray[byte] =
  snapSyncAccountKey(tag.to(Hash256), pv.rootHash.Hash256).toOpenArray

proc hasAccountRec(pv: ProofDb; tag: NodeTag): bool =
  pv.db.contains(pv.mkAccKey(tag))

proc getAccountRec(pv: ProofDb; tag: NodeTag): Result[AccountRec,void] =
  let rec = pv.db.get(pv.mkAccKey(tag))
  if 0 < rec.len:
    noRlpError("read(AccountRec)"):
      return ok(rec.decode(Account).to(AccountRec))
  err()

proc addAccountRec(pv: var ProofDb; tag: NodeTag; rec: AccountRec) =
  if not pv.hasAccountRec(tag):
    pv.db.put(pv.mkAccKey(tag), rlp.encode(rec.to(Account)))
    pv.stat.nAccounts.inc

# -----------

template mkStatusKey(pv: ProofDb; root: TrieHash): openArray[byte] =
  snapSyncStatusKey(root.Hash256).toOpenArray

proc hasStatusRec(pv: ProofDb; root: TrieHash): bool =
  pv.db.contains(pv.mkStatusKey(root))

proc getStatusRec(pv: ProofDb; root: TrieHash): Result[StatusRec,void] =
  let rec = pv.db.get(pv.mkStatusKey(root))
  if 0 < rec.len:
    noRlpError("getStatusRec"):
      return ok(rec.decode(StatusRec))
  err()

proc useStatusRec(pv: ProofDb; root: TrieHash): StatusRec =
  let rec = pv.db.get(pv.mkStatusKey(root))
  if 0 < rec.len:
    noRlpError("findStatusRec"):
      return rec.decode(StatusRec)

proc putStatusRec(pv: ProofDb; root: TrieHash; rec: StatusRec) =
  pv.db.put(pv.mkStatusKey(root), rlp.encode(rec))

# Example trie from https://eth.wiki/en/fundamentals/patricia-tree
#
#   lookup data:
#     "do":    "verb"
#     "dog":   "puppy"
#     "dodge": "coin"
#     "horse": "stallion"
#
#   trie DB:
#     root: [16 A]
#     A:    [* * * * B * * * [20+"orse" "stallion"] * * * * * * *  *]
#     B:    [00+"o" D]
#     D:    [* * * * * * E * * * * * * * * *  "verb"]
#     E:    [17 [* * * * * * [35 "coin"] * * * * * * * * * "puppy"]]
#
#     with first nibble of two-column rows:
#       hex bits | node type  length
#       ---------+------------------
#        0  0000 | extension   even
#        1  0001 | extension   odd
#        2  0010 | leaf        even
#        3  0011 | leaf        odd
#
#    and key path:
#        "do":     6 4 6 f
#        "dog":    6 4 6 f 6 7
#        "dodge":  6 4 6 f 6 7 6 5
#        "horse":  6 8 6 f 7 2 7 3 6 5
#

proc parse(pv: ProofDb; rlpData: Blob): Result[ProofKvp,ProofError]
    {.gcsafe, raises: [Defect, RlpError].} =
  ## Decode a single trie item for adding to the table

  let recTag = rlpData.digestTo(NodeTag)
  when RowColumnParserDump:
    debug "Rlp column parser", recTag
  if pv.hasProofsRec(recTag):
    # No need to do this rec again
    return ok(ProofKvp(key: recTag, data: none(ProofRec)))

  var
    # Inut data
    rlp = rlpData.rlpFromBytes

    # Result data
    blobs = newSeq[Blob](2)      # temporary, cache
    rec = ProofRec(kind: Branch) # part of output, default type
    top = 0                      # count entries

  # Collect lists of either 2 or 17 blob entries.
  for w in rlp.items:
    when RowColumnParserDump:
      debug "Rlp column parser", col=top, data=w.toBytes.pp
    case top
    of 0, 1:
      if not w.isBlob:
        return err(RlpBlobExpected)
      blobs[top] = rlp.read(Blob)
    of 2 .. 15:
      if not rec.vertex[top].init(rlp.read(Blob)):
        return err(RlpBranchLinkExpected)
    of 16:
      if not w.isBlob:
        return err(RlpBlobExpected)
      rec.value = rlp.read(Blob)
    else:
      return err(Rlp2Or17ListEntries)
    top.inc

  when RowColumnParserDump:
    debug "Rlp column parser done collecting columns", col=top

  # Assemble collected data
  case top:
  of 2:
    if blobs[0].len == 0:
      return err(RlpNonEmptyBlobExpected)
    case blobs[0][0] shr 4:
    of 0, 1:
      rec.kind = Extension
      if not (rec.extend.init(blobs[0]) and rec.follow.init(blobs[1])):
        return err(RlpExtPathEncoding)
    of 2, 3:
      rec.kind = Leaf
      if not rec.path.init(blobs[0]):
        return err(RlpLeafPathEncoding)
      rec.payload = blobs[1]
    else:
      return err(RlpRecTypeError)
  of 17:
    # Branch entry, complete the first two vertices
    for n,blob in blobs:
      if not rec.vertex[n].init(blob):
        return err(RlpBranchLinkExpected)
  else:
    return err(Rlp2Or17ListEntries)

  ok(ProofKvp(key: recTag, data: some(rec)))


proc parse(pv: var ProofDb; proof: SnapAccountProof): Result[void,ProofError] =
  ## Decode a list of RLP encoded trie entries and add it to the rec pool
  try:
    for n,rlpRec in proof:
      when RowColumnParserDump:
        debug "Rlp rec parser", rec=n, data=rec.pp

      let kvp = block:
        let rc = pv.parse(rlpRec)
        if rc.isErr:
          return err(rc.error)
        rc.value

      if kvp.data.isNone: # avoids dups, stoll collects references
        pv.collectRefs(kvp.key)
      else:
        pv.addProofsRec(kvp.key, kvp.data.get)
  except RlpError:
    return err(RlpEncoding)
  except KeyError:
    return err(ImpossibleKeyError)

  ok()

proc follow(pv: ProofDb; path: NodeTag): (int, Blob) =
  ## Returns the number of matching digits/nibbles from the argument `tag`
  ## found in the proofs trie.
  var
    inTop = 0
    inPath = path.UInt256.toBytesBE
    recTag = pv.rootTag
    leafBlob: Blob

  when NibbleFollowDump:
    trace "follow", root=pv.rootTag, path

  noRlpError("follow"):
    block loop:
      while true:

        let rec = block:
          let rc = pv.getProofsRec(recTag)
          if rc.isErr:
            break loop
          rc.value

        let recType = rec.kind
        case recType:
        of Branch:
          let
            nibble = inPath.nibble(inTop)
            newTag = rec.vertex[nibble]
          when NibbleFollowDump:
            trace "follow branch", recType, recTag, inTop, nibble, newTag
          recTag = newTag

        of Leaf:
          for n in 0 ..< rec.path.len:
            if rec.path[n] != inPath.nibble(inTop + n):
              inTop += n
              when NibbleFollowDump:
                let tail = rec.path
                trace "follow leaf failed", recType, recTag, tail
              break loop
          inTop += rec.path.len
          leafBlob = rec.payload
          when NibbleFollowDump:
            trace "follow leaf", recType, recTag, inTop, done=true
          break loop

        of Extension:
          for n in 0 ..< rec.extend.len:
            if rec.extend[n] != inPath.nibble(inTop + n):
              inTop += n
              when NibbleFollowDump:
                let tail = rec.extend
                trace "follow extension failed", recType, recTag, tail
              break loop
          inTop += rec.extend.len
          let newTag = rec.follow
          when NibbleFollowDump:
            trace "follow extension", recType, recTag, inTop, newTag
          recTag = newTag

        # end case
        inTop.inc

      # end while
      inTop.dec

  when NibbleFollowDump:
    trace "follow done", tag, inTop

  (inTop, leafBlob)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(pv: var ProofDb; db: TrieDatabaseRef) =
  pv = ProofDb(db: db)

# ------------------------------------------------------------------------------
# Public functions, transaction frame
# ------------------------------------------------------------------------------

proc isMergeTx*(pv: ProofDb): bool =
  ## The function returns `true` exactly if a merge transaction was initialised
  ## with `mergeBegin()`.
  not pv.dbTx.isNil

proc mergeBegin*(pv: var ProofDb; root: TrieHash): bool =
  ## Prepare the system for accepting data input unless there is an open
  ## transaction, already. The function returns `true` if
  ## * There was no transaction initialised, yet
  ## * There is an open transaction for the same state root argument `root`
  ## In all other cases, `false` is returned.
  if pv.dbTx.isNil:
    # Update state root
    pv.rootTag = root.to(NodeTag)
    pv.rootHash = root
    # Fetch status record for this `root`
    pv.stat = pv.useStatusRec(root)
    # New DB transaction
    pv.dbTx = pv.db.beginTransaction
    return true
  # Make sure that the state roots are the same
  pv.rootHash == root

proc mergeCommit*(pv: var ProofDb): bool =
  ## Accept merges and clear rollback journal if there was a transaction
  ## initialised with `mergeBegin()`. If successful, `true` is returned, and
  ## `false` otherwise.
  if not pv.dbTx.isNil:
    pv.dbTx.commit
    pv.dbTx = nil
    pv.clearJournal()
    pv.putStatusRec(pv.rootHash, pv.stat) # persistent new status for this root
    return true

proc mergeRollback*(pv: var ProofDb): bool =
  ## Rewind discaring merges and clear rollback journal if there was a
  ## transaction initialised with `mergeBegin()`. If successful, `true` is
  ## returned, and `false` otherwise.
  if not pv.dbTx.isNil:
    pv.dbTx.rollback
    pv.dbTx = nil
    # restore previous status for this root
    pv.stat = pv.useStatusRec(pv.rootHash)
    pv.clearJournal()
    return true

proc merge*(
    pv: var ProofDb;
    proofs: SnapAccountProof
      ): Result[void,ProofError] =
  ## Merge account proofs (as received with the snap message `AccountRange`)
  ## into the database. A rollback journal is maintained so that this operation
  ## can be reverted.
  if pv.dbTx.isNil:
    return err(MissingMergeBeginDirective)
  let rc = pv.parse(proofs)
  if rc.isErr:
    trace "Merge() proof failed", proofs=proofs.len, error=rc.error
    return err(rc.error)
  ok()

proc merge*(
    pv: var ProofDb;
    base: NodeTag;
    acc: seq[SnapAccount]
      ): Result[void,ProofError] =
  ## Merge accounts (as received with the snap message `AccountRange`) into
  ## the database. A rollback journal is maintained so that this operation
  ## can be reverted.
  if pv.dbTx.isNil:
    return err(MissingMergeBeginDirective)
  if acc.len != 0:
    # Verify lower bound
    if acc[0].accHash < base:
      return err(AccountSmallerThanBase)
    # Verify strictly increasing account hashes
    for n in 1 ..< acc.len:
      if acc[n].accHash <= acc[n-1].accHash:
        return err(AccountsNotSrictlyIncreasing)
    # Add to database
    for sa in acc:
      pv.addAccountRec(sa.accHash, sa.accBody.to(AccountRec))
    # Stash boundary values, needed for later boundary proof
    pv.newAccs.add (base, acc[^1].accHash)
  ok()

proc mergeValidate*(pv: ProofDb): Result[void,ProofError] =
  ## Verify non-commited accounts and proofs:
  ## * The prosfs entries must all be referenced from within the rollback
  ##   journal
  ## * For each group of accounts, the base `NodeTag` must be found in the
  ##   proof database with a partial path of length ???
  ## * The last entry in a group of accounts must habe the `accBody` in the
  ##   proof database
  if pv.dbTx.isNil:
    return err(MissingMergeBeginDirective)

  # Make sure that all recs are referenced
  if 0 < pv.newProofs.len:
    #debug "Ref check",refPool=pv.refPool.pp(pv),newProofs=pv.newProofs.pp(pv)
    for tag in pv.newProofs:
      if tag notin pv.refPool and tag != pv.rootTag:
        #debug "Unreferenced proofs rec", tag, tag=tag.pp(pv)
        return err(RowUnreferenced)

  ## verify accounts
  for (baseTag,accTag) in pv.newAccs:

    # Validate increasing accounts

    # Base and last account must be in database
    let
      nBaseDgts = pv.follow(baseTag)[0]
      (nAccDgts, accData) = pv.follow(accTag)

    # Verify account base
    # ...

    # Verify last account
    if nAccDgts == 64:
      let rc = pv.getAccountRec(accTag)
      if rc.isOk:
        noRlpError("validate(Account)"):
          if accData.decode(Account) == rc.value.to(Account):
            continue

    # This account list did not verify
    return err(LastAccountProofFailed)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergeProved*(
    pv: var ProofDb;
    root: TrieHash;
    base: NodeTag;
    data: WorkerAccountRange
      ): Result[void,ProofError] =
  ## Validate and merge accounts and proofs (as received with the snap message
  ## `AccountRange`) into the database. Any open transaction initialised with
  ## `mergeBegin()` is continued ans finished.
  if not pv.mergeBegin(root):
    return err(StateRootDiffers)

  block:
    let rc = pv.merge(data.proof)
    if rc.isErr:
      trace "Merge proofs failed",
        proof=data.proof.len, error=rc.error
      discard pv.mergeRollback()
      return err(rc.error)
  block:
    let rc = pv.merge(base, data.accounts)
    if rc.isErr:
      trace "Merge accounts failed",
        accounts=data.accounts.len, error=rc.error
      discard pv.mergeRollback()
      return err(rc.error)
  block:
    let rc = pv.mergeValidate()
    if rc.isErr:
      trace "Proofs or accounts do not valdate",
        accounts=data.accounts.len, error=rc.error
      discard pv.mergeRollback()
      return err(rc.error)

  #trace "Merge accounts and proofs ok",
  #  root=pv.rootTag,  base=base, accounts=data.accounts.pp, proof=data.proof.pp
  discard pv.mergeCommit()
  ok()

proc proofsLen*(pv: ProofDb; root: TrieHash): int =
  ## Number of entries in the proofs table for the argument state root `root`.
  if pv.rootHash == root:
    pv.stat.nProofs
  else:
    pv.useStatusRec(pv.rootHash).nProofs

proc accountsLen*(pv: ProofDb; root: TrieHash): int =
  ## Number of entries in the accounts table for the argument state root `root`.
  if pv.rootHash == root:
    pv.stat.nAccounts
  else:
    pv.useStatusRec(pv.rootHash).nAccounts

proc journalLen*(pv: ProofDb): (bool,int,int,int) =
  ## Size of the current rollback journal:
  ## * oepn transaction, see `mergeBegin()`
  ## * number of added recs
  ## * number of added references implied by recs
  ## * number of added accounts
  (not pv.dbTx.isNil, pv.newProofs.len, pv.refPool.len, pv.newAccs.len)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
