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
  std/[algorithm, hashes, sequtils, sets, strutils, strformat, tables],
  chronos,
  eth/[common/eth_types, p2p, rlp, trie/db],
  nimcrypto/keccak,
  stew/[byteutils, interval_set],
  stint,
  ../../../../db/storage_types,
  "../../.."/[protocol, types],
  ../../path_desc

{.push raises: [Defect].}

logScope:
  topics = "snap-proof"

const
  RowColumnParserDump = false
  NibbleFollowDump = false # true

type
  ProofError* = enum
    RlpEncoding,
    RlpBlobExpected,
    RlpNonEmptyBlobExpected,
    RlpBranchLinkExpected,
    RlpListExpected,
    Rlp2Or17ListEntries,
    RlpExtPathEncoding,
    RlpLeafPathEncoding,
    RlpRowTypeError,
    ImpossibleKeyError,
    RowUnreferenced,
    AccountSmallerThanBase,
    AccountsNotSrictlyIncreasing,
    LastAccountProofFailed

  ProofRowType = enum
    Branch,
    Extension,
    Leaf

  ProofRowRef = ref object
    case kind: ProofRowType
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
    data: ProofRowRef

  ProofDbRef* = ref object
    keyMap: Table[NodeTag,uint]              # for debugging only

    rootTag: NodeTag
    accounts: TrieDatabaseRef                # partial accounts database
    proofs: TrieDatabaseRef                  # table: NodeTag -> ProofXRowRef
    proofTx: DbTransaction
    proofBias: int

    proofCount: int
    newAccs: seq[(NodeTag,seq[SnapAccount])] # newly created accounts
    newRows: seq[NodeTag]                    # newly added rows
    refPool: HashSet[NodeTag]                # newly referencing rows

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

template noRlpError(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg

template noFmtError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg


func nibble(a: array[32,byte]; inx: int): int =
  let byteInx = inx shr 1
  if byteInx < 32:
    if (inx and 1) == 0:
      result = (a[byteInx] shr 4).int
    else:
      result = (a[byteInx] and 15).int

proc snapDecode(blob: Blob; T: type Account): Result[T,void] =
  ## Decode blob with `Account` data.
  ## TODO: These are `snap/1` encoded data which silghtly differ from standard
  ##       encoding.
  var rlp = blob.rlpFromBytes
  try:
    let acc = rlp.read(Account)
    return ok(acc)
  except RlpError:
    discard
  err()

proc clearJournal(pv: ProofDBRef) =
  pv.newAccs.setLen(0)
  pv.newRows.setLen(0)
  pv.refPool.clear

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

import
  ../../../../constants

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

proc toKey(a: NodeTag; pv: ProofDbRef): uint =
  noKeyError("pp(NodeTag)"):
    if not pv.keyMap.hasKey(a):
      pv.keyMap[a] = pv.keyMap.len.uint + 1
    result = pv.keyMap[a]

proc pp(a: NodeTag; pv: ProofDbRef): string =
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
  noFmtError("pp(Account)"):
    result = &"({a.nonce},{a.balance},{a.storageRoot},{a.codeHash})"

proc pp(sa: SnapAccount): string =
  "(" & $sa.accHash & "," & sa.accBody.pp & ")"

proc pp(al: seq[SnapAccount]): string =
  result = "  @["
  noFmtError("pp(seq[SnapAccount])"):
    for n,rec in al:
      result &= &"|    # <{n}>|    {rec.pp},"
  if 10 < result.len:
    result[^1] = ']'
  else:
    result &= "]"

proc pp(blobs: seq[Blob]): string =
  result = "  @["
  noFmtError("pp(seq[Blob])"):
    for n,rec in blobs:
      result &= "|    # <" & $n & ">|    \"" & rec.pp & "\".hexToSeqByte,"
  if 10 < result.len:
    result[^1] = ']'
  else:
    result &= "]"

proc pp(hs: seq[NodeTag]; pv: ProofDbRef): string =
 "<" & hs.mapIt(it.pp(pv)).join(",") & ">"

proc pp(hs: HashSet[NodeTag]; pv: ProofDbRef): string =
  "{" & toSeq(hs.items).mapIt(it.toKey(pv)).sorted.mapIt($it).join(",") & "}"

proc pp(row: ProofRowRef; pv: ProofDbRef): string =
  if row.isNil:
    return "nil"
  noFmtError("pp(ProofRowRef)"):
    case row.kind:
    of Branch: result &=
      "b(" & row.vertex.mapIt(it.pp(pv)).join(",") & "," &
        row.value.pp.pp(true) & ")"
    of Leaf: result &=
      "l(" & ($row.path).pp(true) & "," & row.payload.pp.pp(true) & ")"
    of Extension: result &=
      "x(" & ($row.extend).pp(true) & "," & row.follow.pp(pv) & ")"

proc pp(q: seq[ProofKvp]; pv: ProofDbRef): string =
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

template toAccKey(tag: NodeTag): openArray[byte] =
  let key = tag.to(Hash256).snapSyncAccountKey
  key.data.toOpenArray(0, int(key.dataEndPos))

template toProofKey(tag: NodeTag): openArray[byte] =
  let key = tag.to(Hash256).snapSyncProofKey
  key.data.toOpenArray(0, int(key.dataEndPos))

proc read(rlp: var Rlp; T: type ProofRowRef): T =
  ## RLP mixin
  noRlpError("read(ProofRowRef)"):
    new result
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

proc append(rlpWriter: var RlpWriter; row: ProofRowRef) =
  ## RLP mixin
  append(rlpWriter, row.kind)
  startList(rlpWriter, 2)
  case row.kind:
  of Branch:
    append(rlpWriter, row.vertex)
    append(rlpWriter, row.value)
  of Extension:
    dbAppend(rlpWriter, row.extend)
    append(rlpWriter, row.follow)
  of Leaf:
    dbAppend(rlpWriter, row.path)
    append(rlpWriter, row.payload)

proc getProofsRow(pv: ProofDBRef; tag: NodeTag): ProofRowRef =
  let rowData = pv.proofs.get(tag.toProofKey)
  if 0 < rowData.len:
    result = rowData.decode(ProofRowRef)

proc hasProofsRow(pv: ProofDBRef; tag: NodeTag): bool =
  pv.proofs.contains(tag.toProofKey)

proc delProofsRow(pv: ProofDBRef; tag: NodeTag): bool =
  if pv.hasProofsRow(tag):
    pv.proofs.del(tag.toProofKey)
    pv.proofCount.dec
    return true

proc collectRefs(pv: ProofDBRef; row: ProofRowRef) =
  case row.kind:
  of Branch:
    for v in row.vertex:
      pv.refPool.incl v
  of Extension:
    pv.refPool.incl row.follow
  of Leaf:
    discard

proc collectRefs(pv: ProofDBRef; tag: NodeTag) =
  let row = pv.getProofsRow(tag)
  if not row.isNil:
    pv.collectRefs(row)

proc addProofsRow(pv: ProofDBRef; tag: NodeTag; row: ProofRowRef) =
  #debug "addProofsRow", size=pv.proofCount, tag=tag.pp(pv), row=row.pp(pv)
  pv.proofs.put(tag.toProofKey, rlp.encode(row))
  pv.proofCount.inc
  # Add references to pool
  pv.newRows.add tag
  # Always add references, the row might have been added earlier outside
  # the current transaction.
  pv.collectRefs(row)

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

proc parse(pv: ProofDBRef; rlpData: Blob): Result[ProofKvp,ProofError]
    {.gcsafe, raises: [Defect, RlpError].} =
  ## Decode a single trie item for adding to the table
  let rowTag = rlpData.digestTo(NodeTag)
  when RowColumnParserDump:
    debug "Rlp column parser", rowTag
  if pv.hasProofsRow(rowTag):
    # No need to do this row again
    return ok(ProofKvp(key: rowTag))

  var
    # Inut data
    rlp = rlpData.rlpFromBytes

    # Result data
    blobs = newSeq[Blob](2)         # temporary, cache
    row = ProofRowRef(kind: Branch) # part of output, default type
    top = 0                         # count entries

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
      if not row.vertex[top].init(rlp.read(Blob)):
        return err(RlpBranchLinkExpected)
    of 16:
      if not w.isBlob:
        return err(RlpBlobExpected)
      row.value = rlp.read(Blob)
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
      row.kind = Extension
      if not (row.extend.init(blobs[0]) and row.follow.init(blobs[1])):
        return err(RlpExtPathEncoding)
    of 2, 3:
      row.kind = Leaf
      if not row.path.init(blobs[0]):
        return err(RlpLeafPathEncoding)
      row.payload = blobs[1]
    else:
      return err(RlpRowTypeError)
  of 17:
    # Branch entry, complete the first two vertices
    for n,blob in blobs:
      if not row.vertex[n].init(blob):
        return err(RlpBranchLinkExpected)
  else:
    return err(Rlp2Or17ListEntries)

  ok(ProofKvp(key: rowTag, data: row))


proc parse(pv: ProofDBRef; proof: SnapAccountProof): Result[void,ProofError] =
  ## Decode a list of RLP encoded trie entries and add it to the row pool
  try:
    for n,rlpRow in proof:
      when RowColumnParserDump:
        debug "Rlp row parser", row=n, data=row.pp
      let rc = pv.parse(rlpRow)
      if rc.isErr:
        return err(rc.error)

      let row = rc.value.data
      if row.isNil: # avoid dups
        pv.collectRefs(rc.value.key)
      else:
        pv.addProofsRow(rc.value.key, row)
  except RlpError:
    return err(RlpEncoding)
  except KeyError:
    return err(ImpossibleKeyError)

  ok()

proc follow(pv: ProofDBRef; path: NodeTag): (int, Blob) =
  ## Returns the number of matching digits/nibbles from the argument `tag`
  ## found in the proofs trie.
  var
    inTop = 0
    inPath = path.UInt256.toBytesBE
    rowTag = pv.rootTag
    leafBlob: Blob

  when NibbleFollowDump:
    trace "follow", root=pv.rootTag, path

  noRlpError("follow"):
    block loop:
      while true:
        let row = pv.getProofsRow(rowTag)
        if row.isNil:
          break
        let rowType = row.kind
        case rowType:
        of Branch:
          let
            nibble = inPath.nibble(inTop)
            newTag = row.vertex[nibble]
          when NibbleFollowDump:
            trace "follow branch", rowType, rowTag, inTop, nibble, newTag
          rowTag = newTag

        of Leaf:
          for n in 0 ..< row.path.len:
            if row.path[n] != inPath.nibble(inTop + n):
              inTop += n
              when NibbleFollowDump:
                let tail = row.path
                trace "follow leaf failed", rowType, rowTag, tail
              break loop
          inTop += row.path.len
          leafBlob = row.payload
          when NibbleFollowDump:
            trace "follow leaf", rowType, rowTag, inTop, done=true
          break loop

        of Extension:
          for n in 0 ..< row.extend.len:
            if row.extend[n] != inPath.nibble(inTop + n):
              inTop += n
              when NibbleFollowDump:
                let tail = row.extend
                trace "follow extension failed", rowType, rowTag, tail
              break loop
          inTop += row.extend.len
          let newTag = row.follow
          when NibbleFollowDump:
            trace "follow extension", rowType, rowTag, inTop, newTag
          rowTag = newTag

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

proc init*(T: type ProofDBRef; root: TrieHash): T =
  result = T(
    rootTag: root.Hash256.to(NodeTag),
    proofs: newMemoryDB(),
    accounts: newMemoryDB())
  result.proofBias = result.proofs.totalRecordsInMemoryDB

proc clear*(pv: ProofDBRef) =
  ## Resets everything except state root.
  pv.refPool.clear
  pv.newRows.setLen(0)
  pv.accounts = newMemoryDB()
  pv.proofs = newMemoryDB()
  pv.proofTx = nil

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc merge*(
    pv: ProofDBRef;
    proofs: SnapAccountProof
      ): Result[void,ProofError] =
  ## Merge account proofs (as received with the snap message `AccountRange`)
  ## into the database. A rollback journal is maintained so that this operation
  ## can be reverted.
  if pv.proofTx.isNil:
    pv.proofCount = pv.proofs.totalRecordsInMemoryDB
    pv.refPool.incl pv.rootTag
    pv.proofTx = pv.proofs.beginTransaction
  let rc = pv.parse(proofs)
  if rc.isErr:
    trace "Merge() proof failed", proofs=proofs.len, error=rc.error
    return err(rc.error)
  ok()

proc merge*(
    pv: ProofDBRef;
    base: NodeTag;
    acc: seq[SnapAccount]
      ): Result[void,ProofError] =
  ## Merge accounts (as received with the snap message `AccountRange`) into
  ## the database. A rollback journal is maintained so that this operation
  ## can be reverted.
  if acc.len != 0:
    # Stash accounts until commit
    pv.newAccs.add (base,acc)
  ok()


proc commit*(pv: ProofDBRef) =
  ## Clear rollback journal.
  if not pv.proofTx.isNil:
    for (_,subLst) in pv.newAccs:
      for sa in subLst:
        pv.accounts.put(sa.accHash.toAccKey, rlp.encode(sa.accBody))
    pv.clearJournal()
    pv.proofTx.commit
    pv.proofTx = nil

proc rollback*(pv: ProofDBRef) =
  ## Rewind and clear rollback journal.
  if not pv.proofTx.isNil:
    pv.clearJournal()
    pv.proofTx.rollback
    pv.proofTx = nil


proc validate*(pv: ProofDBRef): Result[void,ProofError] =
  ## Verify non-commited accounts and proofs:
  ## * The prosfs entries must all be referenced from within the rollback
  ##   journal
  ## * For each group of accounts, the base `NodeTag` must be found in the
  ##   proof database with a partial path of length ???
  ## * The last entry in a group of accounts must habe the `accBody` in the
  ##   proof database

  # Make sure that all rows are referenced
  if 0 < pv.newRows.len:
    #debug "Reference check",refPool=pv.refPool.pp(pv),newRows=pv.newRows.pp(pv)
    for tag in pv.newRows:
      if tag notin pv.refPool:
        # debug "Unreferenced proofs row", tag, tag=tag.pp(pv)
        return err(RowUnreferenced)

  ## verify accounts
  for (base,accList) in pv.newAccs:

    # Validate increasing accounts
    if accList[0].accHash < base:
      return err(AccountSmallerThanBase)
    for n in 1 ..< accList.len:
      if accList[n].accHash <= accList[n-1].accHash:
        return err(AccountsNotSrictlyIncreasing)

    # Base and last account must be in database
    let
      nBaseDgts = pv.follow(base)[0]
      (nAccDgts, accData) = pv.follow(accList[^1].accHash)

    # Verify account base
    # ...

    # Verify last account
    if nAccDgts == 64:
     let rc = accData.snapDecode(Account)
     if rc.isOk:
       if rc.value == accList[^1].accBody:
         continue

    # This account list did not verify
    return err(LastAccountProofFailed)

  ok()


proc mergeProved*(
    pv: ProofDBRef;
    base: NodeTag;
    accounts: seq[SnapAccount];
    proofs: SnapAccountProof
      ): Result[void,ProofError] =
  ## Validate and merge accounts and proofs (as received with the snap message
  ## `AccountRange`) into the database.
  block:
    let rc = pv.merge(proofs)
    if rc.isErr:
      trace "Merge proofs failed",
        proofs=proofs.len, error=rc.error
      pv.rollback()
      return err(rc.error)
  block:
    let rc = pv.merge(base, accounts)
    if rc.isErr:
      trace "Merge accounts failed",
        accounts=accounts.len, error=rc.error
      pv.rollback()
      return err(rc.error)
  block:
    let rc = pv.validate()
    if rc.isErr:
      trace "Proofs or accounts do not valdate",
        accounts=accounts.len, error=rc.error
      pv.rollback()
      return err(rc.error)

  #trace "Merge accounts and proofs ok",
  #  root=pv.rootTag,  base=base, accounts=accounts.pp, proofs=proofs.pp
  pv.commit()
  ok()

proc proofsLen*(pv: ProofDBRef): int =
  ## Number of entries in the proofs table
  if pv.proofTx.isNil:
    pv.proofs.totalRecordsInMemoryDB - pv.proofBias
  else:
    pv.proofCount - pv.proofBias

proc accountsLen*(pv: ProofDBRef): int =
  ## Number of entries in the accounts table
  pv.accounts.totalRecordsInMemoryDB

proc journalLen*(pv: ProofDBRef): (int,int,int) =
  ## Size of the roolback journal:
  ## * number of added rows
  ## * number of added references implied by rows
  ## * number of added accounts
  (pv.newRows.len, pv.refPool.len, pv.newAccs.len)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
