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
  eth/[common/eth_types, p2p, rlp],
  eth/trie/[db, nibbles, trie_defs],
  nimcrypto/keccak,
  stew/[byteutils, interval_set, objects],
  stint,
  "../../../.."/[db/storage_types, constants],
  "../../.."/[protocol, types],
  ../../path_desc,
  ../worker_desc

{.push raises: [Defect].}

logScope:
  topics = "snap-proof"

const
  RowColumnParserDump = false
  NibbleFollowDump = false # or true

type
  PmtError* = enum
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
    AccountBaseProofFailed
    LastAccountProofFailed
    MissingMergeBeginDirective
    StateRootDiffers
    ExceptioninMergeProof

  ByteArray32 =
    array[32,byte]

  NodeKey =               ## Internal DB record reference type
    distinct ByteArray32

  StatusRec = object
    nPmts: int            ## Number of records in the trie table for root key

    accTop: NodeKey       ## Accounts linked list latest
    nAccounts: int        ## Number of accounts records

    backLink: NodeKey     ## Keep in a simple linked list
    nStatus: int          ## Number of items in linked list

  AccountData* = object
    ## Account + meta data
    account*: Account     ## Account data, ie. `nonce`, `balance`, etc.
    proved*: bool         ## Account has a verified path in the proof table

  AccountRec = object ##\
    ## Database records for accounts
    data: AccountData     ## Account + meta data
    backLink: NodeKey     ## Keep in a simple linked list
    nAccounts: int        ## Number of items in remaining linked list


  ProofDbJournal = object
    dbTx: DbTransaction              ## Rollback state capture
    rootKey: NodeKey                 ## Current root node
    newAccs: seq[(NodeKey,NodeKey)]  ## New accounts group: (base,last)
    newPmts: seq[NodeKey]            ## Newly added proofs records
    refPool: HashSet[NodeKey]        ## New proofs references recs
    peer: Peer                       ## For log messages

  ProofDb* = object
    keyMap: TableRef[NodeKey,uint]   ## For debugging only (will go away)
    db: TrieDatabaseRef              ## General database
    jrn: ProofDbJournal              ## Transaction journal

const
  ValidBasePathMin = 6 # official docu missing, constant deducted from log data
  ZeroNodeKey = NodeKey.default

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(tag: NodeTag; T: type NodeKey): T =
  tag.UInt256.toBytesBE.T

proc to(key: NodeKey; T: type NodeTag): T =
  UInt256.fromBytesBE(key.ByteArray32).T

proc to[W: TrieHash|Hash256](key: NodeKey; T: type W): T =
  result.Hash256.data = key.ByteArray32

proc to[W: TrieHash|Hash256](h: W; T: type NodeKey): T =
  h.Hash256.data.T


proc `==`(a, b: NodeKey): bool =
  a.ByteArray32 == b.ByteArray32

proc `<`(a, b: NodeKey): bool =
  a.ByteArray32 == b.ByteArray32

proc `$`(key: NodeKey): string =
  $key.to(NodeTag)

proc hash(a: NodeKey): Hash =
  a.ByteArray32.hash

proc digestTo(data: Blob; T: type NodeKey): T =
  keccak256.digest(data).data.T


proc init(key: var NodeKey; data: openArray[byte]): bool =
  if data.len == 32:
    key = toArray(32,data).NodeKey
    return true
  elif data.len == 0:
    key.reset
    return true
  elif data.len < 32:
    let offset = 32 - data.len
    for n in 0 ..< data.len:
      key.ByteArray32[offset + n] = data[n]
    return true

proc convertTo(data: openArray[byte]; T: type NodeKey): T =
  let withinRangeOk = result.init(data)
  doAssert withinRangeOk


proc read(rlp: var Rlp, T: type NodeKey): T
    {.gcsafe, raises: [Defect,RlpError]} =
  rlp.read(Hash256).data.T

proc append(writer: var RlpWriter, key: NodeKey) =
  writer.append(key.to(Hash256))

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
  elif a == emptyRlpHash:
    "emptyRlpHash"
  elif a == blankStringHash:
    "blankStringHash"
  else:
    a.data.mapIt(it.toHex(2)).join[56 .. 63].toLowerAscii

proc pp(a: NodeKey; collapse = true): string =
  a.to(Hash256).pp(collapse)

proc toKey(a: NodeKey; pv: ProofDb): uint =
  noPpError("pp(NodeKey)"):
    if not pv.keyMap.hasKey(a):
      pv.keyMap[a] = pv.keyMap.len.uint + 1
    result = pv.keyMap[a]

proc pp(a: NodeKey; pv: ProofDb): string =
  "$" & $a.toKey(pv)

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

proc pp(branch: array[17,Blob]; pv: ProofDb): string =
  result = "["
  noPpError("pp(array[17,Blob])"):
    for a in 0 .. 15:
      result &= branch[a].convertTo(NodeKey).pp(pv) & ","
  result &= branch[16].pp & "]"

proc pp(branch: array[16,NodeKey]; pv: ProofDb): string =
  result = "["
  noPpError("pp(array[17,Blob])"):
    for a in 0 .. 15:
      result &= branch[a].pp(pv) & ","
  result[^1] = ']'

proc pp(hs: seq[NodeKey]; pv: ProofDb): string =
 "<" & hs.mapIt(it.pp(pv)).join(",") & ">"

proc pp(hs: HashSet[NodeKey]; pv: ProofDb): string =
  "{" &
    toSeq(hs.items).mapIt(it.toKey(pv)).sorted.mapIt("$" & $it).join(",") & "}"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template mkStatusKey(root: NodeKey): openArray[byte] =
  snapSyncStatusKey(root.to(Hash256)).toOpenArray

proc useStatusRec(pv: ProofDb; root: NodeKey): StatusRec
    {.gcsafe, raises: [Defect,RlpError]} =
  let rec = pv.db.get(root.mkStatusKey())
  if 0 < rec.len:
    return rec.decode(StatusRec)

proc putStatusRec(pv: ProofDb; root: NodeKey; rec: var StatusRec)
    {.gcsafe, raises: [Defect,RlpError]} =
  # Update linked list
    if rec.nStatus == 0:
      doAssert rec.backLink == ZeroNodeKey
      #
      # Linked list:
      #
      #   +-- zeroRec <-- [] <-- [] ... <-- []
      #   |                                 ^
      #   |                                 |
      #   +---------------------------------+
      #
      var zeroRec = pv.useStatusRec(ZeroNodeKey)
      rec.backLink = zeroRec.backLink
      zeroRec.backLink = root
      #
      # Update size of linked list
      rec.nStatus = zeroRec.nStatus + 1
      zeroRec.nStatus = rec.nStatus
      #
      # Store head record
      pv.db.put(ZeroNodeKey.mkStatusKey(), rlp.encode(zeroRec))
    pv.db.put(root.mkStatusKey(), rlp.encode(rec))

# -----------

proc getPmtRec(pv: ProofDb; key: Blob): Result[Blob,void] =
  let recData = pv.db.get(key)
  if 0 < recData.len:
    return ok(recData)
  err()

proc addPmtRec(pv: var ProofDb; recData: Blob)
    {.gcsafe, raises: [Defect,RlpError]} =
  let key = (keccak recData).data
  if not pv.db.contains(key):
    #
    # Update status record
    var statRec = pv.useStatusRec(pv.jrn.rootKey)
    statRec.nPmts.inc
    #
    # Store status record
    pv.db.put(pv.jrn.rootKey.mkStatusKey(), rlp.encode(statRec))
    #
    # Store proof table record
    pv.db.put(key, recData)
    #
    # Add to update journal
    pv.jrn.newPmts.add key.NodeKey
    #
    #debug "addPmtRec", size=statRec.nPmts, key=key.pp(pv), rec=recData.pp

# -----------

template mkAccountKey(key, root: NodeKey): openArray[byte] =
  snapSyncAccountKey(key.to(Hash256), root.to(Hash256)).toOpenArray

proc getAccountData(pv: ProofDb; key: NodeKey): Result[AccountData,void]
    {.gcsafe, raises: [Defect,RlpError]} =
  ## Get account, returns error on failure
  let rec = pv.db.get(key.mkAccountKey(pv.jrn.rootKey))
  if 0 < rec.len:
    return ok(rec.decode(AccountRec).data)
  err()

proc useAccountRec(pv: ProofDb; key, root: NodeKey): AccountRec
    {.gcsafe, raises: [Defect,RlpError]} =
  ## Get account, returns empty account on failure
  let rec = pv.db.get(key.mkAccountKey(root))
  if 0 < rec.len:
    return rec.decode(AccountRec)

proc putAccountData(pv: var ProofDb; key: NodeKey; accData: AccountData)
    {.gcsafe, raises: [Defect,RlpError]} =
  ## Update account data record
  var accRec = pv.useAccountRec(key, pv.jrn.rootKey)
  accRec.data = accData

  if accRec.nAccounts == 0:
    var statRec = pv.useStatusRec(pv.jrn.rootKey)
    #
    # Linked list:
    #
    #   [] <-- [] <-- [] ... <-- accRec
    #                              ^
    #                              |
    #   statRec.accTop ------------+
    #
    accRec.backLink = statRec.accTop
    statRec.accTop = key
    #
    # Update size of linked list
    accRec.nAccounts = statRec.nAccounts + 1
    statRec.nAccounts = accRec.nAccounts
    #
    # Store status record
    pv.putStatusRec(pv.jrn.rootKey, statRec)

  # Store/update account record
  pv.db.put(key.mkAccountKey(pv.jrn.rootKey), rlp.encode(accRec))

proc putAccount(pv: var ProofDb; key: NodeKey; acc: Account)
    {.gcsafe, raises: [Defect,RlpError]} =
  ## Add/apdate account, no explicit meta data
  pv.putAccountData(key, AccountData(account: acc))


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

proc parse(pv: var ProofDb; recData: Blob): Result[void,PmtError]
    {.gcsafe, raises: [Defect, RlpError].} =
  ## Decode a single trie item for adding to the table and add it to the
  ## database. Branch and exrension record links are collected.

  when RowColumnParserDump:
    debug "Rlp column parser", key=recData.digestTo(NodeKey).pp(pv)

  var
    rlp = recData.rlpFromBytes
    blobs = newSeq[Blob](2)         # temporary, cache
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
      var nodeKey: NodeKey
      if not nodeKey.init(rlp.read(Blob)):
        return err(RlpBranchLinkExpected)
      # Update ref pool
      pv.jrn.refPool.incl nodeKey
    of 16:
      if not w.isBlob:
        return err(RlpBlobExpected)
    else:
      return err(Rlp2Or17ListEntries)
    top.inc

  when RowColumnParserDump:
    debug "Rlp column parser done collecting columns", col=top

  # Verify extension data
  case top
  of 2:
    if blobs[0].len == 0:
      return err(RlpNonEmptyBlobExpected)
    let isLeaf = (hexPrefixDecode blobs[0])[0]
    if not isLeaf:
      var nodeKey: NodeKey
      if not nodeKey.init(blobs[1]):
        return err(RlpExtPathEncoding)
      # Update ref pool
      pv.jrn.refPool.incl nodeKey
  of 17:
    for blob in blobs:
      var nodeKey: NodeKey
      if not nodeKey.init(blob):
        return err(RlpBranchLinkExpected)
      # Update ref pool
      pv.jrn.refPool.incl nodeKey
  else:
    discard

  # Add to database
  pv.addPmtRec(recData)

  ok()


proc parse(pv: var ProofDb; proof: SnapAccountProof): Result[void,PmtError] =
  ## Decode a list of RLP encoded trie entries and add it to the database
  try:
    for n,rlpRec in proof:
      when RowColumnParserDump:
        debug "Rlp rec parser", rec=n, data=rlpRec.pp
      let rc = pv.parse(rlpRec)
      if rc.isErr:
        return err(rc.error)
  except RlpError:
    return err(RlpEncoding)
  except KeyError:
    return err(ImpossibleKeyError)

  ok()

# ------------------------------------------------------------------------------
# Private walk along hexary trie records
# ------------------------------------------------------------------------------

proc follow(pv: ProofDb; root: NodeKey; path: NibblesSeq): (int, bool, Blob)
    {.gcsafe, raises: [Defect,RlpError]} =
  ## Returns the number of matching digits/nibbles from the argument `path`
  ## found in the proofs trie.
  let
    nNibbles = path.len
  var
    inPath = path
    recKey = root.ByteArray32.toSeq
    leafBlob: Blob
    emptyRef = false

  when NibbleFollowDump:
    trace "follow", rootKey=root.pp(pv), path

  while true:
    let rc = pv.getPmtRec(recKey)
    if rc.isErr:
      break

    var nodeRlp = rlpFromBytes rc.value
    case nodeRlp.listLen:
    of 2:
      let
        (isLeaf, pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
        sharedNibbles = sharedPrefixLen(inPath, pathSegment)
        fullPath = sharedNibbles == pathSegment.len
        inPathLen = inPath.len
      inPath = inPath.slice(sharedNibbles)

      # Leaf node
      if isLeaf:
        let leafMode = sharedNibbles == inPathLen
        if fullPath and leafMode:
          leafBlob = nodeRlp.listElem(1).toBytes
        when NibbleFollowDump:
          let nibblesLeft = inPathLen - sharedNibbles
          trace "follow leaf",
            fullPath, leafMode, sharedNibbles, nibblesLeft,
            pathSegment, newPath=inPath
        break

      # Extension node
      if fullPath:
        let branch = nodeRlp.listElem(1)
        if branch.isEmpty:
          when NibbleFollowDump:
            trace "follow extension", newKey="n/a"
          emptyRef = true
          break
        recKey = branch.toBytes
        when NibbleFollowDump:
          trace "follow extension",
            newKey=recKey.convertTo(NodeKey).pp(pv), newPath=inPath
      else:
        when NibbleFollowDump:
          trace "follow extension",
            fullPath, sharedNibbles, pathSegment,
            inPathLen, newPath=inPath
        break

    of 17:
      # Branch node
      if inPath.len == 0:
        leafBlob = nodeRlp.listElem(1).toBytes
        break
      let
        inx = inPath[0].int
        branch = nodeRlp.listElem(inx)
      if branch.isEmpty:
        when NibbleFollowDump:
          trace "follow branch", newKey="n/a"
        emptyRef = true
        break
      inPath = inPath.slice(1)
      recKey = branch.toBytes
      when NibbleFollowDump:
        trace "follow branch",
          newKey=recKey.convertTo(NodeKey).pp(pv), inx, newPath=inPath

    else:
      when NibbleFollowDump:
        trace "follow oops",
          nColumns = nodeRlp.listLen
      break

  # end while

  let pathLen = nNibbles - inPath.len

  when NibbleFollowDump:
    trace "follow done",
      recKey, emptyRef, pathLen, leafSize=leafBlob.len

  (pathLen, emptyRef, leafBlob)


proc follow(pv: ProofDb; root, path: NodeKey): (int, bool, Blob)
    {.gcsafe, raises: [Defect,RlpError]} =
  ## Variant of `follow()`
  pv.follow(root, path.ByteArray32.initNibbleRange)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(pv: var ProofDb; db: TrieDatabaseRef) =
  pv = ProofDb(db: db, keyMap: newTable[NodeKey,uint]())

# ------------------------------------------------------------------------------
# Public functions, transaction frame
# ------------------------------------------------------------------------------

proc isMergeTx*(pv: ProofDb): bool =
  ## The function returns `true` exactly if a merge transaction was initialised
  ## with `mergeBegin()`.
  not pv.jrn.dbTx.isNil

proc mergeBegin*(pv: var ProofDb; peer: Peer, root: TrieHash): bool =
  ## Prepare the system for accepting data input unless there is an open
  ## transaction, already. The function returns `true` if
  ## * There was no transaction initialised, yet
  ## * There is an open transaction for the same state root argument `root`
  ## In all other cases, `false` is returned.
  ##
  ## Note that the `peer` argument is for log messages, only.
  ##
  ## This function is save but needs to be handled in concert similat to
  ## ::
  ##        mergeBegin()
  ##        merge()
  ##        ..
  ##        mergeVerify()
  ##        mergeCommit()
  ##
  ## so it probably wise to use `mergeProved()` rather than the command above.
  ## The main reason for exposing the detailed function is debugging and
  ## verification.
  if pv.jrn.dbTx.isNil:
    #
    # Update state root and peer
    pv.jrn.rootKey = root.to(NodeKey)
    pv.jrn.peer = peer
    #
    # New DB transaction
    pv.jrn.dbTx = pv.db.beginTransaction
    return true

  # Otherwise make sure that the state roots are the same
  pv.jrn.rootKey == root.to(NodeKey)

proc mergeCommit*(pv: var ProofDb): bool =
  ## Accept merges and clear rollback journal if there was a transaction
  ## initialised with `mergeBegin()`. If successful, `true` is returned, and
  ## `false` otherwise.
  ##
  ## See also comment on `mergeBegin()` regarding the use of this function.
  if not pv.jrn.dbTx.isNil:
    pv.jrn.dbTx.commit
    pv.jrn.reset
    return true

proc mergeRollback*(pv: var ProofDb): bool =
  ## Rewind discaring merges and clear rollback journal if there was a
  ## transaction initialised with `mergeBegin()`. If successful, `true` is
  ## returned, and `false` otherwise.
  ##
  ## See also comment on `mergeBegin()` regarding the use of this function.
  if not pv.jrn.dbTx.isNil:
    pv.jrn.dbTx.rollback
    pv.jrn.reset
    return true

proc merge*(
    pv: var ProofDb;
    proof: SnapAccountProof
      ): Result[void,PmtError] =
  ## Merge account proofs (as received with the snap message `AccountRange`)
  ## into the database. A rollback journal is maintained so that this operation
  ## can be reverted.
  ##
  ## See also comment on `mergeBegin()` regarding the use of this function.
  if pv.jrn.dbTx.isNil:
    debug "Stash SnapAccountProof"
    return err(MissingMergeBeginDirective)

  # Initialise for logging
  let (peer, proofs, accounts) = (
    pv.jrn.peer, pv.jrn.newPmts.len, pv.jrn.newAccs.len)

  let rc = pv.parse(proof)
  if rc.isErr:
    trace "Stash SnapAccountProof",
      peer, proofs, accounts, error=rc.error
    return err(rc.error)
  ok()

proc merge*(
    pv: var ProofDb;
    base: NodeTag;
    acc: seq[SnapAccount]
      ): Result[void,PmtError]
    {.gcsafe, raises: [Defect, RlpError].} =
  ## Merge accounts (as received with the snap message `AccountRange`) into
  ## the database. A rollback journal is maintained so that this operation
  ## can be reverted.
  ##
  ## See also comment on `mergeBegin()` regarding the use of this function.
  if pv.jrn.dbTx.isNil:
    debug "Stash seq[SnapAccount]"
    return err(MissingMergeBeginDirective)

  # Initialise for logging
  let (peer, proofs, accounts) = (
    pv.jrn.peer, pv.jrn.newPmts.len, pv.jrn.newAccs.len)

  if acc.len != 0:
    # Verify lower bound
    if acc[0].accHash < base:
      let error = AccountSmallerThanBase
      trace "Stash seq[SnapAccount]",
        peer, proofs, accounts, base, accounts=acc.len, error
      return err(error)

    # Verify strictly increasing account hashes
    for n in 1 ..< acc.len:
      if acc[n].accHash <= acc[n-1].accHash:
        let error = AccountsNotSrictlyIncreasing
        trace "Stash seq[SnapAccount]",
           peer, proofs, accounts, base, accounts=acc.len, error
        return err(error)

    # Add to database
    for sa in acc:
      pv.putAccount(sa.accHash.to(NodeKey), sa.accBody)

    # Stash boundary values, needed for later boundary proof
    pv.jrn.newAccs.add (base.to(NodeKey), acc[^1].accHash.to(NodeKey))

  ok()

proc mergeValidate*(pv: var ProofDb): Result[void,PmtError]
    {.gcsafe, raises: [Defect, RlpError].} =
  ## Verify non-commited accounts and proofs:
  ## * The prosfs entries must all be referenced from within the rollback
  ##   journal
  ## * For each group of accounts, the base `NodeKey` must be found in the
  ##   proof database with a partial path of length ???
  ## * The last entry in a group of accounts must habe the `accBody` in the
  ##   proof database
  ## The last entry which was validated will be marked as such.
  ##
  ## See also comment on `mergeBegin()` regarding the use of this function.
  if pv.jrn.dbTx.isNil:
    debug "Validate missing begin directive"
    return err(MissingMergeBeginDirective)

  # Initialise for logging
  let (peer, proofs, accounts) = (
    pv.jrn.peer, pv.jrn.newPmts.len, pv.jrn.newAccs.len)

  # Make sure that all recs are referenced
  if 0 < pv.jrn.newPmts.len:
    #debug "Ref check",
    #  refPool=pv.jrn.refPool.pp(pv), newPmts=pv.jrn.newPmts.pp(pv)
    for key in pv.jrn.newPmts:
      if key notin pv.jrn.refPool and key != pv.jrn.rootKey:
        let error = RowUnreferenced
        trace "Validate proof entry refs",
          peer, proofs, accounts, unrefKey=key, error
        return err(error)

  ## Verify accounts (increasing was validated with merge(), already)
  for (baseKey,accKey) in pv.jrn.newAccs:
    # Base and last account must be in database

    # Verify account base
    let (nBaseDgts, emptyBaseRef, _) = pv.follow(pv.jrn.rootKey, baseKey)
    block:
      let error = AccountBaseProofFailed
      if nBaseDgts < ValidBasePathMin:
        trace "Validate: accounts list lower bound",
          peer, proofs, accounts, baseKey, nBaseDgts,
          nBaseDgtsMin=ValidBasePathMin, error
        return err(error)

    # Verify last account
    let (nAccDgts, emptyAccRef, leafData) = pv.follow(pv.jrn.rootKey, accKey)
    block:
      let error = LastAccountProofFailed # if any

      if nAccDgts < 64:
        trace "Validate: accounts list",
          peer, proofs, accounts, accKey, nAccDgts, nAccDgtsMin=64, error
        return err(error)

      let rc = pv.getAccountData(accKey)
      if rc.isOk:
        var accData = rc.value
        let accLeaf = leafData.decode(Account)

        if accLeaf == accData.account:
          accData.proved = true
          pv.putAccountData(accKey, accData)
          continue

        trace "Validate accounts list",
          peer, proofs, accounts, accLeaf, acc=accData.account, error

      # This account list did not verify
      return err(error)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergeProved*(
    pv: var ProofDb;
    peer: Peer,      ## for log messages
    root: TrieHash;  ## state root
    base: NodeTag;   ## before or at first account entry in `data`
    data: WorkerAccountRange
      ): Result[void,PmtError] =
  ## Validate and merge accounts and proofs (as received with the snap message
  ## `AccountRange`) into the database. Any open transaction initialised with
  ## `mergeBegin()` is continued ans finished.
  ##
  ## Note that the `peer` argument is for log messages, only.
  if not pv.mergeBegin(peer, root):
    return err(StateRootDiffers)

  try:
    block:
      let rc = pv.merge(data.proof)
      if rc.isErr:
        discard pv.mergeRollback()
        return err(rc.error)
    block:
      let rc = pv.merge(base, data.accounts)
      if rc.isErr:
        discard pv.mergeRollback()
        return err(rc.error)
    block:
      let rc = pv.mergeValidate()
      if rc.isErr:
        discard pv.mergeRollback()
        return err(rc.error)
  except CatchableError as e:
    error "mergeProved crashed", error = $e.name, msg = e.msg
    discard pv.mergeRollback()
    return err(ExceptioninMergeProof)

    #trace "Merge accounts and proofs ok", peer=pv.jrn.peer, rootKey=pv.rootKey,
  #  base=base, accounts=data.accounts.pp, proof=data.proof.pp
  discard pv.mergeCommit()
  ok()

proc nPmts*(pv: ProofDb; root: TrieHash): int  =
  ## Number of entries in the Patricia Merkle Trie proofs table for the state
  ## root argument  `root`.
  try:
    return pv.useStatusRec(root.to(NodeKey)).nPmts
  except RlpError as e:
    error "nPmts crashed", error = $e.name, msg = e.msg

proc nAccounts*(pv: ProofDb; root: TrieHash): int =
  ## Number of entries in the accounts table for the argument state root `root`.
  try:
    return pv.useStatusRec(root.to(NodeKey)).nAccounts
  except RlpError as e:
    error "nAccounts crashed", error = $e.name, msg = e.msg

proc nStateRoots*(pv: ProofDb): int =
  ## Print the number of known state roots
  try:
    return pv.useStatusRec(ZeroNodeKey).nStatus
  except RlpError as e:
    error "nStateRoots crashed", error = $e.name, msg = e.msg

proc journalSize*(pv: ProofDb): (bool,int,int,int) =
  ## Size of the current rollback journal:
  ## * transaction is open or not, see `mergeBegin()`
  ## * number of added recs
  ## * number of added references implied by recs
  ## * number of added accounts
  (not pv.jrn.dbTx.isNil,
   pv.jrn.newPmts.len,
   pv.jrn.refPool.len,
   pv.jrn.newAccs.len)

# ------------------------------------------------------------------------------
# Iterators
# ------------------------------------------------------------------------------

iterator accounts*(pv: ProofDb; root: TrieHash): (int,NodeTag,AccountData) =
  ## Walk accounts for the argument `root` in reverse storage order. The first
  ## entry of the last triple is always `1`.
  try:
    var nodeKey = pv.useStatusRec(root.to(NodeKey)).accTop
    while nodeKey != ZeroNodeKey:
      let rec = pv.useAccountRec(nodeKey,root.to(NodeKey))
      yield (rec.nAccounts, nodeKey.to(NodeTag), rec.data)
      nodeKey = rec.backLink
  except RlpError as e:
    error "accounts iterator crashed", error = $e.name, msg = e.msg

iterator stateRoots*(pv: ProofDb): (int,TrieHash) =
  ## Walk state root entries in reverse storage order. The first entry
  ## of the last tuple is always `1`.
  try:
    var nodeKey = pv.useStatusRec(ZeroNodeKey).backLink
    while nodeKey != ZeroNodeKey:
      let rec = pv.useStatusRec(nodeKey)
      yield (rec.nStatus, nodeKey.to(TrieHash))
      nodeKey = rec.backLink
  except RlpError as e:
    error "stateRoots iterator crashed", error = $e.name, msg = e.msg

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
