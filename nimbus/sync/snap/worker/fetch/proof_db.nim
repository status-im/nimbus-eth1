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
  eth/[common/eth_types, p2p],
  nimcrypto/keccak,
  stew/[byteutils, interval_set],
  stint,
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

  ProofNodeKey = ##\
    ## Local alias for a `NodeTag` which is `UInt256`. Note that there should
    ## be no more than `high(int)` entries in a table as the `len()` function
    ## returns an `int` value.
    distinct uint32

  ProofRowRef = ref object
    nodeTag: NodeTag              # allows for reverse mapping key -> tag
    case kind: ProofRowType
    of Branch:
      vertex: array[16,ProofNodeKey]
      value: Blob                 # name starts with a `v` as in vertex
    of Extension:
      extend: PathSegment
      follow: ProofNodeKey
    of Leaf:
      path: PathSegment
      payload: Blob               # name starts with a `p` as in path

  ProofKvp = object
    key: ProofNodeKey
    data: ProofRowRef

  ProofDbRef* = ref object
    rootTag: NodeTag
    rootKey: ProofNodeKey

    keys: Table[NodeTag,ProofNodeKey]        # hash -> key mapping
    proofs: Table[ProofNodeKey,ProofRowRef]  # partial trie database
    accounts: Table[NodeTag,Account]         # partial accounts database

    newAccs: seq[(NodeTag,seq[SnapAccount])] # newly created accounts
    newKeys: seq[NodeTag]                    # newly created key map
    newRows: seq[ProofNodeKey]               # newly added rows
    refPool: HashSet[ProofNodeKey]           # newly referenced rows

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

template noFmtError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

proc `==`(a, b: ProofNodeKey): bool {.borrow.}
proc `<`(a, b: ProofNodeKey): bool {.borrow.}

# Handy shortcuts
proc `==`(a: ProofNodeKey; b: static[int]): bool = a == b.ProofNodeKey
proc `<`(a: static[int]; b: ProofNodeKey): bool = a.ProofNodeKey < b

proc `$`(a: ProofNodeKey): string =
  noFmtError("`$`"):
    result = &"${a.uint64:x}"

proc to(n: static[int]; T: type ProofNodeKey): T =
  n.T

func nibble(a: array[32,byte]; inx: int): int =
  let byteInx = inx shr 1
  if byteInx < 32:
    if (inx and 1) == 0:
      result = (a[byteInx] shr 4).int
    else:
      result = (a[byteInx] and 15).int

proc getKey(pv: ProofDbRef; nodeTag: NodeTag): ProofNodeKey =
  ## Simple `NodeTag` -> <key> mapper. New keys are also recorded in the
  ## `unwind` list.
  noKeyError("getKey"):
    if pv.keys.hasKey(nodeTag):
      return pv.keys[nodeTag]

  result = (pv.keys.len + 1).ProofNodeKey
  pv.keys[nodeTag] = result
  pv.newKeys.add nodeTag

  # Special treatment while root is not initialised
  if pv.rootKey == 0:
    if nodeTag == pv.rootTag:
      pv.rootKey = result

proc decode(blob: Blob; T: type Account): Result[T,void] =
  ## Decode blob with `Account` data
  var rlp = blob.rlpFromBytes
  try:
    let acc = rlp.read(Account)
    return ok(acc)
  except RlpError:
    discard
  err()

proc clearJournal(pv: ProofDBRef) =
  pv.newKeys.setLen(0)
  pv.newRows.setLen(0)
  pv.newAccs.setLen(0)
  pv.refPool.clear

#[
proc `==`(a, b: Account): bool =
  ## For debugging, only
  if a.nonce != b.nonce:
    trace "==(Account) nonce", a=a.nonce, b=b.nonce
    return false
  if a.balance != b.balance:
    trace "==(Account) balance", a=a.balance, b=b.balance
    return false
  if a.storageRoot != b.storageRoot:
    trace "==(Account) storageRoot", a=a.storageRoot, b=b.storageRoot
    return false
  if a.codeHash != b.codeHash:
    trace "==(Account) codeHash", a=a.codeHash, b=b.codeHash
    return false
  true
#]#

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

proc pp(a: ProofNodeKey): string =
  if 0 < a:
    result = $a

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

proc pp(row: ProofRowRef): string =
  if row.isNil:
    return "nil"
  noFmtError("pp(ProofRowRef)"):
    case row.kind:
    of Branch: result &=
      "b(" & row.vertex.mapIt(it.pp).join(",") & "," & row.value.pp & ")"
    of Leaf: result &=
      "l(" & ($row.path).pp(true) & "," & row.payload.pp & ")"
    of Extension: result &=
      "x(" & ($row.extend).pp(true) & "," & row.follow.pp & ")"

proc pp(q: seq[ProofKvp]): string =
  result="@["
  for kvp in q:
    result &= "(" & kvp.key.pp & "," & kvp.data.pp & "),"
  if q.len == 0:
    result &= "]"
  else:
    result[^1] = ']'

proc dumpProofs(pv: ProofDBRef): string =
  noFmtError("dumpProofs"):
    for key in toSeq(pv.proofs.keys).sorted:
      var keyPp = key.pp
      if key == pv.rootKey:
        keyPp[0] = '*'
      result &= &"({keyPp},{pv.proofs[key].pp})|"
  if 0 < result.len: # cut off trailing '|'
    result.setLen(result.len-1)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

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
# This is sort of implemented as
#
#   keys:
#     root: $1 -- the state root is always $1, $0 is unused in table
#     A:    $2
#     B:    $3
#     C:    $4
#     D:    $5
#     E:    $6
#     F:    $7 -- resolving embedded reference
#     G:    $8 -- resolving embedded reference
#     H:    $9 -- resolving embedded reference
#
#   proofs:
#     root: x(16, $2)
#     $2:   b(,,,,$3,,,,$7,,,,,,,,)
#     $3:   x(00+"o", $5)
#     $5:   b(,,,,,,$6,,,,,,,,,,"verb")
#     $6:   x(17, $8)
#     $7:   l(20+"orse", "stallion")
#     $8:   b(,,,,,,$9,,,,,,,,,,"puppy")
#     $9:   l(35, "coin")
#
#     with
#       b(..) for a branch node
#       x(..) for an extension node
#       l(..) for a leaf node

proc parse(pv: ProofDBRef; rlpData: Blob): Result[ProofKvp,ProofError]
    {.gcsafe, raises: [Defect,RlpError].} =
  ## Decode a single trie item for adding to the table
  let
    rowKey = pv.getKey(rlpData.digestTo(NodeTag)) # map of row hash
  if pv.proofs.hasKey(rowKey):
    # No need to do this row again
    return ok(ProofKvp(key: rowKey))

  var
    # Inut data
    rlp = rlpData.rlpFromBytes

    # Result data
    blobs = newSeq[Blob](2)         # temporary, cache
    row = ProofrowRef(kind: Branch) # part of output, default type
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
      var tag: NodeTag
      if not tag.init(rlp.read(Blob)):
        return err(RlpBranchLinkExpected)
      row.vertex[top] = pv.getKey(tag)
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
      var tag: NodeTag
      if not (row.extend.init(blobs[0]) and tag.init(blobs[1])):
        return err(RlpExtPathEncoding)
      row.follow = pv.getKey(tag)
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
      var tag: NodeTag
      if not tag.init(blob):
        return err(RlpBranchLinkExpected)
      row.vertex[n] = pv.getKey(tag)
  else:
    return err(Rlp2Or17ListEntries)

  ok(ProofKvp(key: rowKey, data: row))


proc parse(pv: ProofDBRef; proof: SnapAccountProof): Result[void,ProofError] =
  ## Decode a list of RLP encoded trie entries and add it to the row pool
  try:
    for n,rlpRow in proof:
      when RowColumnParserDump:
        debug "Rlp row parser", row=n, data=row.pp
      let rc = pv.parse(rlpRow)
      if rc.isErr:
        return err(rc.error)

      # Queue in `unwind` list unless seen, already
      var row: ProofRowRef
      if rc.value.data.isNil:
        row = pv.proofs[rc.value.key]
      else:
        row = rc.value.data
        pv.proofs[rc.value.key] = row
        pv.newRows.add rc.value.key

      # Add references to pool
      case row.kind:
      of Branch:
        for v in row.vertex:
          pv.refPool.incl v
      of Extension:
        pv.refPool.incl row.follow
      of Leaf:
        discard
  except RlpError:
    return err(RlpEncoding)
  except KeyError:
    return err(ImpossibleKeyError)

  ok()


proc follow(pv: ProofDBRef; tag: NodeTag): (int, Blob) =
  ## Returns the number of matching digits/nibbles from the argument `tag`
  ## found in the proofs trie.
  var
    inTop = 0
    inPath = tag.UInt256.toBytesBE
    rowKey = pv.rootKey
    leafBlob: Blob

  when NibbleFollowDump:
    trace "follow", root=pv.rootKey, tag

  noKeyError("follow"):
    block loop:
      while pv.proofs.hasKey(rowKey):
        let
          row = pv.proofs[rowKey]
          rowType = row.kind

        case rowType:
        of Branch:
          let
            nibble = inPath.nibble(inTop)
            newKey = row.vertex[nibble]
          when NibbleFollowDump:
            trace "follow branch", rowType, rowKey, inTop, nibble, newKey
          rowKey = newKey

        of Leaf:
          for n in 0 ..< row.path.len:
            if row.path[n] != inPath.nibble(inTop + n):
              inTop += n
              when NibbleFollowDump:
                trace "follow leaf failed", rowType, rowKey, tail=row.path
              break loop
          inTop += row.path.len
          leafBlob = row.payload
          when NibbleFollowDump:
            trace "follow leaf", rowType, rowKey, inTop, done=true
          break loop

        of Extension:
          for n in 0 ..< row.extend.len:
            if row.extend[n] != inPath.nibble(inTop + n):
              inTop += n
              #when NibbleFollowDump:
              trace "follow extension failed", rowType, rowKey, tail=row.path
              break loop
          inTop += row.path.len
          let newKey = row.follow
          #when NibbleFollowDump:
          trace "follow extension", rowType, rowKey, inTop, newKey
          rowKey = newKey

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
  T(rootTag: root.Hash256.to(NodeTag))

proc clear*(pv: ProofDBRef) =
  ## Resets everything except state root.
  pv.rootKey.reset
  pv.keys.clear
  pv.proofs.clear
  pv.newKeys.setLen(0)
  pv.newRows.setLen(0)
  pv.refPool.clear

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
  for (_,subLst) in pv.newAccs:
    for sa in subLst:
      pv.accounts[sa.accHash] = sa.accBody
  pv.clearJournal()

proc rollback*(pv: ProofDBRef) =
  ## Rewind and clear rollback journal.
  # noKeyError("rollback"):
  for tag in pv.newKeys:
    pv.keys.del(tag)
  for key in pv.newRows:
    pv.proofs.del(key)
  pv.clearJournal()
  if pv.keys.len == 0:
    pv.rootKey.reset

proc validate*(pv: ProofDBRef): Result[void,ProofError] =
  ## Verify non-commited accounts and proofs:
  ## * The prosfs entries must all be referenced from within the rollback
  ##   journal
  ## * For each group of accounts, the base `NodeTag` must be found in the
  ##   proof database with a partial path of length ???
  ## * The last entry in a group of accounts must habe the `accBody` in the
  ##   proof database
  noKeyError("verify"):
    for key in pv.newRows:
      let tag = pv.proofs[key].nodeTag
      if pv.keys[tag] notin pv.refPool:
        return err(RowUnreferenced)

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
     let rc = accData.decode(Account)
     if rc.isOk:
       if rc.value == accList[^1].accBody:
         trace "validate accounts", nBaseDgts, nAccList=accList.len
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
  pv.proofs.len

proc accountsLen*(pv: ProofDBRef): int =
  ## Number of entries in the accounts table
  pv.accounts.len

proc journalLen*(pv: ProofDBRef): (int,int,int,int) =
  ## Size of the roolback journal:
  ## * number of added keys
  ## * number of added rows
  ## * number of added row traversal references
  (pv.newKeys.len, pv.newRows.len, pv.refPool.len, pv.newAccs.len)


proc dump*(pv: ProofDBRef): string =
  ## Debugging only -- function will go away
  noKeyError("dump"):
    let
      proofsPp = pv.dumpProofs.replace("|","\n  ")
      newKeysPp = pv.newKeys.mapIt(pv.keys[it]).sorted.mapIt(it.pp).join(",")
      newRowsPp = pv.newRows.sorted.mapIt(it.pp).join(",")
      refPoolPp = toSeq(pv.refPool.items).sorted.mapIt(it.pp).join(",")
    result =
      "proofs:\n  " & proofsPp & "\n" &
      "newKeys:\n  " & newKeysPp & "\n" &
      "newRows:\n  " & newRowsPp & "\n" &
      "refPool:\n  " & refPoolPp & "\n"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
