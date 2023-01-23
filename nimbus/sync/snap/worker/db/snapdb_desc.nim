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
  std/[sequtils, tables],
  chronicles,
  eth/[common, p2p, trie/db, trie/nibbles],
  ../../../../db/[select_backend, storage_types],
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_import, hexary_nearby,
       hexary_paths, rocky_bulk_load]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

const
  extraTraceMessages = false or true

  RockyBulkCache* = "accounts.sst"
    ## Name of temporary file to accomodate SST records for `rocksdb`

type
  SnapDbRef* = ref object
    ## Global, re-usable descriptor
    keyMap: Table[RepairKey,uint]    ## For debugging only (will go away)
    db: TrieDatabaseRef              ## General database
    rocky: RocksStoreRef             ## Set if rocksdb is available

  SnapDbBaseRef* = ref object of RootRef
    ## Session descriptor
    xDb: HexaryTreeDbRef             ## Hexary database, memory based
    base: SnapDbRef                  ## Back reference to common parameters
    root*: NodeKey                   ## Session DB root node key

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

proc toKey(a: RepairKey; pv: SnapDbRef): uint =
  if not a.isZero:
    noPpError("pp(RepairKey)"):
      if not pv.keyMap.hasKey(a):
        pv.keyMap[a] = pv.keyMap.len.uint + 1
      result = pv.keyMap[a]

proc toKey(a: RepairKey; ps: SnapDbBaseRef): uint =
  a.toKey(ps.base)

proc toKey(a: NodeKey; ps: SnapDbBaseRef): uint =
  a.to(RepairKey).toKey(ps)

proc toKey(a: NodeTag; ps: SnapDbBaseRef): uint =
  a.to(NodeKey).toKey(ps)

proc ppImpl(a: RepairKey; pv: SnapDbRef): string =
  if a.isZero: "ø" else:"$" & $a.toKey(pv)

# ------------------------------------------------------------------------------
# Debugging, pretty printing
# ------------------------------------------------------------------------------

proc pp*(a: NodeKey; ps: SnapDbBaseRef): string =
  if a.isZero: "ø" else:"$" & $a.toKey(ps)

proc pp*(a: RepairKey; ps: SnapDbBaseRef): string =
  if a.isZero: "ø" elif a.isNodeKey: "$" & $a.toKey(ps) else: "@" & $a.toKey(ps)

proc pp*(a: NodeTag; ps: SnapDbBaseRef): string =
  a.to(NodeKey).pp(ps)

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc clearRockyCacheFile(rocky: RocksStoreRef): bool =
  if not rocky.isNil:
    # A cache file might hang about from a previous crash
    try:
      discard rocky.clearCacheFile(RockyBulkCache)
      return true
    except OSError as e:
      error "Cannot clear rocksdb cache", exception=($e.name), msg=e.msg

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapDbRef;
    db: TrieDatabaseRef
      ): T =
  ## Main object constructor
  T(db: db)

proc init*(
    T: type SnapDbRef;
    db: ChainDb
      ): T =
  ## Variant of `init()` allowing bulk import on rocksdb backend
  result = T(db: db.trieDB, rocky: db.rocksStoreRef)
  if not result.rocky.clearRockyCacheFile():
    result.rocky = nil

proc init*(
    T: type HexaryTreeDbRef;
    pv: SnapDbRef;
      ): T =
  ## Constructor for inner hexary trie database
  let xDb = HexaryTreeDbRef()
  xDb.keyPp = proc(key: RepairKey): string = key.ppImpl(pv) # will go away
  return xDb

proc init*(
    T: type HexaryTreeDbRef;
    ps: SnapDbBaseRef;
      ): T =
  ## Constructor variant
  HexaryTreeDbRef.init(ps.base)

# ---------------

proc init*(
    ps: SnapDbBaseRef;
    pv: SnapDbRef;
    root: NodeKey;
      ) =
  ## Session base constructor
  ps.base = pv
  ps.root = root
  ps.xDb = HexaryTreeDbRef.init(pv)

proc init*(
    T: type SnapDbBaseRef;
    ps: SnapDbBaseRef;
    root: NodeKey;
      ): T =
  ## Variant of session base constructor
  new result
  result.init(ps.base, root)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc hexaDb*(ps: SnapDbBaseRef): HexaryTreeDbRef =
  ## Getter, low level access to underlying session DB
  ps.xDb

proc rockDb*(ps: SnapDbBaseRef): RocksStoreRef =
  ## Getter, low level access to underlying persistent rock DB interface
  ps.base.rocky

proc kvDb*(ps: SnapDbBaseRef): TrieDatabaseRef =
  ## Getter, low level access to underlying persistent key-value DB
  ps.base.db

proc kvDb*(pv: SnapDbRef): TrieDatabaseRef =
  ## Getter, low level access to underlying persistent key-value DB
  pv.db

# ------------------------------------------------------------------------------
# Public functions, select sub-tables for persistent storage
# ------------------------------------------------------------------------------

proc toAccountsKey*(a: NodeKey): ByteArray33 =
  a.ByteArray32.snapSyncAccountKey.data

proc toStorageSlotsKey*(a: NodeKey): ByteArray33 =
  a.ByteArray32.snapSyncStorageSlotKey.data

proc toStateRootKey*(a: NodeKey): ByteArray33 =
  a.ByteArray32.snapSyncStateRootKey.data

template toOpenArray*(k: ByteArray32): openArray[byte] =
  k.toOpenArray(0, 31)

template toOpenArray*(k: ByteArray33): openArray[byte] =
  k.toOpenArray(0, 32)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbBackendRocksDb*(pv: SnapDbRef): bool =
  ## Returns `true` if rocksdb features are available
  not pv.rocky.isNil

proc dbBackendRocksDb*(ps: SnapDbBaseRef): bool =
  ## Returns `true` if rocksdb features are available
  not ps.base.rocky.isNil

proc mergeProofs*(
    ps: SnapDbBaseRef;        ## Session database
    peer: Peer;               ## For log messages
    proof: seq[Blob];         ## Node records
    freeStandingOk = false;   ## Remove freestanding nodes
      ): Result[void,HexaryError]
      {.gcsafe, raises: [Defect,RlpError,KeyError].} =
  ## Import proof records (as received with snap message) into a hexary trie
  ## of the repair table. These hexary trie records can be extended to a full
  ## trie at a later stage and used for validating account data.
  let
    db = ps.hexaDb
  var
    nodes: HashSet[RepairKey]
    refs = @[ps.root.to(RepairKey)].toHashSet

  for n,rlpRec in proof:
    let report = db.hexaryImport(rlpRec, nodes, refs)
    if report.error != NothingSerious:
      let error = report.error
      trace "mergeProofs()", peer, item=n, proofs=proof.len, error
      return err(error)

  # Remove free standing nodes (if any)
  if 0 < nodes.len:
    let rest = nodes - refs
    if 0 < rest.len:
      if freeStandingOk:
        trace "mergeProofs() detected unrelated nodes", peer, nodes=nodes.len
        discard
      else:
        # Delete unreferenced nodes
        for nodeKey in nodes:
          db.tab.del(nodeKey)
        trace "mergeProofs() ignoring unrelated nodes", peer, nodes=nodes.len

  ok()


proc verifyLowerBound*(
    ps: SnapDbBaseRef;        ## Database session descriptor
    peer: Peer;               ## For log messages
    base: NodeTag;            ## Before or at first account entry in `data`
    first: NodeTag;           ## First account key
      ): Result[void,HexaryError]
      {.gcsafe, raises: [Defect, KeyError].} =
  ## Verify that `base` is to the left of the first leaf entry and there is
  ## nothing in between.
  var error: HexaryError

  let rc = base.hexaryNearbyRight(ps.root, ps.hexaDb)
  if rc.isErr:
    error = rc.error
  elif first == rc.value:
    return ok()
  else:
    error = LowerBoundProofError

  when extraTraceMessages:
    trace "verifyLowerBound()", peer, base=base.to(NodeKey).pp,
      first=first.to(NodeKey).pp, error
  err(error)


proc verifyNoMoreRight*(
    ps: SnapDbBaseRef;        ## Database session descriptor
    peer: Peer;               ## For log messages
    base: NodeTag;            ## Before or at first account entry in `data`
      ): Result[void,HexaryError]
      {.gcsafe, raises: [Defect, KeyError].} =
  ## Verify that there is are no more leaf entries to the right of and
  ## including `base`.
  let
    root = ps.root.to(RepairKey)
    base = base.to(NodeKey)
  if base.hexaryPath(root, ps.hexaDb).hexaryNearbyRightMissing(ps.hexaDb):
    return ok()

  let error = LowerBoundProofError
  when extraTraceMessages:
    trace "verifyLeftmostBound()", peer, base=base.pp, error
  err(error)

# ------------------------------------------------------------------------------
# Debugging (and playing with the hexary database)
# ------------------------------------------------------------------------------

proc assignPrettyKeys*(ps: SnapDbBaseRef) =
  ## Prepare for pretty pringing/debugging. Run early enough this function
  ## sets the root key to `"$"`, for instance.
  noPpError("validate(1)"):
    # Make keys assigned in pretty order for printing
    var keysList = toSeq(ps.hexaDb.tab.keys)
    let rootKey = ps.root.to(RepairKey)
    discard rootKey.toKey(ps)
    if ps.hexaDb.tab.hasKey(rootKey):
      keysList = @[rootKey] & keysList
    for key in keysList:
      let node = ps.hexaDb.tab[key]
      discard key.toKey(ps)
      case node.kind:
      of Branch: (for w in node.bLink: discard w.toKey(ps))
      of Extension: discard node.eLink.toKey(ps)
      of Leaf: discard

proc dumpPath*(ps: SnapDbBaseRef; key: NodeTag): seq[string] =
  ## Pretty print helper compiling the path into the repair tree for the
  ## argument `key`.
  noPpError("dumpPath"):
    let rPath= key.hexaryPath(ps.root, ps.hexaDb)
    result = rPath.path.mapIt(it.pp(ps.hexaDb)) & @["(" & rPath.tail.pp & ")"]

proc dumpHexaDB*(ps: SnapDbBaseRef; indent = 4): string =
  ## Dump the entries from the a generic accounts trie. These are
  ## key value pairs for
  ## ::
  ##   Branch:    ($1,b(<$2,$3,..,$17>,))
  ##   Extension: ($18,e(832b5e..06e697,$19))
  ##   Leaf:      ($20,l(cc9b5d..1c3b4,f84401..f9e5129d[#70]))
  ##
  ## where keys are typically represented as `$<id>` or `¶<id>` or `ø`
  ## depending on whether a key is final (`$<id>`), temporary (`¶<id>`)
  ## or unset/missing (`ø`).
  ##
  ## The node types are indicated by a letter after the first key before
  ## the round brackets
  ## ::
  ##   Branch:    'b', 'þ', or 'B'
  ##   Extension: 'e', '€', or 'E'
  ##   Leaf:      'l', 'ł', or 'L'
  ##
  ## Here a small letter indicates a `Static` node which was from the
  ## original `proofs` list, a capital letter indicates a `Mutable` node
  ## added on the fly which might need some change, and the decorated
  ## letters stand for `Locked` nodes which are like `Static` ones but
  ## added later (typically these nodes are update `Mutable` nodes.)
  ##
  ## Beware: dumping a large database is not recommended
  ps.hexaDb.pp(ps.root,indent)

proc hexaryPpFn*(ps: SnapDbBaseRef): HexaryPpFn =
  ## Key mapping function used in `HexaryTreeDB`
  ps.hexaDb.keyPp

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
