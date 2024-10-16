# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- a Patricia Trie with labeled edges
## ===============================================
##
## These data structures allow to overlay the *Patricia Trie* with *Merkel
## Trie* hashes. See the `README.md` in the `aristo` folder for documentation.
##
## Some semantic explanations;
##
## * HashKey, NodeRef etc. refer to the standard/legacy `Merkle Patricia Tree`
## * VertexID, VertexRef, etc. refer to the `Aristo Trie`
##
{.push raises: [].}

import
  std/[hashes, sets, tables],
  eth/common,
  results,
  ./aristo_constants,
  ./aristo_desc/[desc_error, desc_identifiers, desc_nibbles, desc_structural],
  minilru


from ./aristo_desc/desc_backend
  import BackendRef

# Not auto-exporting backend
export
  tables, aristo_constants, desc_error, desc_identifiers, desc_nibbles,
  desc_structural, minilru, common

type
  AristoTxRef* = ref object
    ## Transaction descriptor
    db*: AristoDbRef                  ## Database descriptor
    parent*: AristoTxRef              ## Previous transaction
    txUid*: uint                      ## Unique ID among transactions
    level*: int                       ## Stack index for this transaction

  DudesRef = ref object
    ## List of peers accessing the same database. This list is layzily allocated
    ## and might be kept with a single entry, i.e. so that `{centre} == peers`.
    ##
    centre: AristoDbRef               ## Link to peer with write permission
    peers: HashSet[AristoDbRef]       ## List of all peers

  AristoDbRef* = ref object
    ## Three tier database object supporting distributed instances.
    top*: LayerRef                    ## Database working layer, mutable
    stack*: seq[LayerRef]             ## Stashed immutable parent layers
    balancer*: LayerRef               ## Balance out concurrent backend access
    backend*: BackendRef              ## Backend database (may well be `nil`)

    txRef*: AristoTxRef               ## Latest active transaction
    txUidGen*: uint                   ## Tx-relative unique number generator
    dudes: DudesRef                   ## Related DB descriptors

    accLeaves*: LruCache[Hash32, VertexRef]
      ## Account path to payload cache - accounts are frequently accessed by
      ## account path when contracts interact with them - this cache ensures
      ## that we don't have to re-traverse the storage trie for every such
      ## interaction
      ## TODO a better solution would probably be to cache this in a type
      ## exposed to the high-level API

    stoLeaves*: LruCache[Hash32, VertexRef]
      ## Mixed account/storage path to payload cache - same as above but caches
      ## the full lookup of storage slots

    # Debugging data below, might go away in future
    xMap*: Table[HashKey,RootedVertexID] ## For pretty printing/debugging

  Leg* = object
    ## For constructing a `VertexPath`
    wp*: VidVtxPair                ## Vertex ID and data ref
    nibble*: int8                  ## Next vertex selector for `Branch` (if any)

  Hike* = object
    ## Trie traversal path
    root*: VertexID                ## Handy for some fringe cases
    legs*: ArrayBuf[NibblesBuf.high + 1, Leg] ## Chain of vertices and IDs
    tail*: NibblesBuf              ## Portion of non completed path

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

template mixUp*(accPath, stoPath: Hash32): Hash32 =
  # Insecure but fast way of mixing the values of two hashes, for the purpose
  # of quick lookups - this is certainly not a good idea for general Hash32
  # values but account paths are generated from accounts which would be hard
  # to create pre-images for, for the purpose of collisions with a particular
  # storage slot
  var v {.noinit.}: Hash32
  for i in 0..<v.data.len:
    # `+` wraps leaving all bits used
    v.data[i] = accPath.data[i] + stoPath.data[i]
  v

func getOrVoid*[W](tab: Table[W,VertexRef]; w: W): VertexRef =
  tab.getOrDefault(w, VertexRef(nil))

func getOrVoid*[W](tab: Table[W,NodeRef]; w: W): NodeRef =
  tab.getOrDefault(w, NodeRef(nil))

func getOrVoid*[W](tab: Table[W,HashKey]; w: W): HashKey =
  tab.getOrDefault(w, VOID_HASH_KEY)

func getOrVoid*[W](tab: Table[W,RootedVertexID]; w: W): RootedVertexID =
  tab.getOrDefault(w, default(RootedVertexID))

func getOrVoid*[W](tab: Table[W,HashSet[RootedVertexID]]; w: W): HashSet[RootedVertexID] =
  tab.getOrDefault(w, default(HashSet[RootedVertexID]))

# --------

func isValid*(vtx: VertexRef): bool =
  vtx != VertexRef(nil)

func isValid*(nd: NodeRef): bool =
  nd != NodeRef(nil)

func isValid*(pid: PathID): bool =
  pid != VOID_PATH_ID

func isValid*(layer: LayerRef): bool =
  layer != LayerRef(nil)

func isValid*(root: Hash32): bool =
  root != EMPTY_ROOT_HASH

func isValid*(key: HashKey): bool =
  assert key.len != 32 or key.to(Hash32).isValid
  0 < key.len

func isValid*(vid: VertexID): bool =
  vid != VertexID(0)

func isValid*(rvid: RootedVertexID): bool =
  rvid.vid.isValid and rvid.root.isValid

func isValid*(sqv: HashSet[RootedVertexID]): bool =
  sqv.len > 0

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

# Hash set helper
func hash*(db: AristoDbRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](db).hash

# ------------------------------------------------------------------------------
# Public functions, `dude` related
# ------------------------------------------------------------------------------

func isCentre*(db: AristoDbRef): bool =
  ## This function returns `true` is the argument `db` is the centre (see
  ## comments on `reCentre()` for details.)
  ##
  db.dudes.isNil or db.dudes.centre == db

func getCentre*(db: AristoDbRef): AristoDbRef =
  ## Get the centre descriptor among all other descriptors accessing the same
  ## backend database (see comments on `reCentre()` for details.)
  ##
  if db.dudes.isNil: db else: db.dudes.centre

proc reCentre*(db: AristoDbRef): Result[void,AristoError] =
  ## Re-focus the `db` argument descriptor so that it becomes the centre.
  ## Nothing is done if the `db` descriptor is the centre, already.
  ##
  ## With several descriptors accessing the same backend database there is a
  ## single one that has write permission for the backend (regardless whether
  ## there is a backend, at all.) The descriptor entity with write permission
  ## is called *the centre*.
  ##
  ## After invoking `reCentre()`, the argument database `db` can only be
  ## destructed by `finish()` which also destructs all other descriptors
  ## accessing the same backend database. Descriptors where `isCentre()`
  ## returns `false` must be single destructed with `forget()`.
  ##
  if not db.dudes.isNil:
    db.dudes.centre = db
  ok()

proc fork*(
    db: AristoDbRef;
    noTopLayer = false;
    noFilter = false;
      ): Result[AristoDbRef,AristoError] =
  ## This function creates a new empty descriptor accessing the same backend
  ## (if any) database as the argument `db`. This new descriptor joins the
  ## list of descriptors accessing the same backend database.
  ##
  ## After use, any unused non centre descriptor should be destructed via
  ## `forget()`. Not doing so will not only hold memory ressources but might
  ## also cost computing ressources for maintaining and updating backend
  ## filters when writing to the backend database .
  ##
  ## If the argument `noFilter` is set `true` the function will fork directly
  ## off the backend database and ignore any filter.
  ##
  ## If the argument `noTopLayer` is set `true` the function will provide an
  ## uninitalised and inconsistent (!) descriptor object without top layer.
  ## This setting avoids some database lookup for cases where the top layer
  ## is redefined anyway.
  ##
  # Make sure that there is a dudes list
  if db.dudes.isNil:
    db.dudes = DudesRef(centre: db, peers: @[db].toHashSet)

  let clone = AristoDbRef(
    dudes:   db.dudes,
    backend: db.backend,
    accLeaves: db.accLeaves,
    stoLeaves: db.stoLeaves,
  )

  if not noFilter:
    clone.balancer = db.balancer # Ref is ok here (filters are immutable)

  if not noTopLayer:
    clone.top = LayerRef.init()
    if not db.balancer.isNil:
      clone.top.vTop = db.balancer.vTop
    else:
      let rc = clone.backend.getTuvFn()
      if rc.isOk:
        clone.top.vTop = rc.value
      elif rc.error != GetTuvNotFound:
        return err(rc.error)

  # Add to peer list of clones
  db.dudes.peers.incl clone

  ok clone

iterator forked*(db: AristoDbRef): tuple[db: AristoDbRef, isLast: bool] =
  ## Interate over all non centre descriptors (see comments on `reCentre()`
  ## for details.)
  ##
  ## The second `isLast` yielded loop entry is `true` if the yielded tuple
  ## is the last entry in the list.
  ##
  if not db.dudes.isNil:
    var nLeft = db.dudes.peers.len
    for dude in db.dudes.peers.items:
      if dude != db.dudes.centre:
        nLeft.dec
        yield (dude, nLeft == 1)

func nForked*(db: AristoDbRef): int =
  ## Returns the number of non centre descriptors (see comments on `reCentre()`
  ## for details.) This function is a fast version of `db.forked.toSeq.len`.
  if not db.dudes.isNil:
    return db.dudes.peers.len - 1


proc forget*(db: AristoDbRef): Result[void,AristoError] =
  ## Destruct the non centre argument `db` descriptor (see comments on
  ## `reCentre()` for details.)
  ##
  ## A non centre descriptor should always be destructed after use (see also
  ## comments on `fork()`.)
  ##
  if db.isCentre:
    err(DescNotAllowedOnCentre)
  elif db notin db.dudes.peers:
    err(DescStaleDescriptor)
  else:
    db.dudes.peers.excl db         # Unlink argument `db` from peers list
    ok()

proc forgetOthers*(db: AristoDbRef): Result[void,AristoError] =
  ## For the centre argument `db` descriptor (see comments on `reCentre()`
  ## for details), destruct all other descriptors accessing the same backend.
  ##
  if not db.dudes.isNil:
    if db.dudes.centre != db:
      return err(DescMustBeOnCentre)

    db.dudes = DudesRef(nil)
  ok()

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

iterator rstack*(db: AristoDbRef): LayerRef =
  # Stack in reverse order
  for i in 0..<db.stack.len:
    yield db.stack[db.stack.len - i - 1]

proc deltaAtLevel*(db: AristoDbRef, level: int): LayerRef =
  if level == 0:
    db.top
  elif level > 0:
    doAssert level <= db.stack.len
    db.stack[^level]
  elif level == -1:
    doAssert db.balancer != nil
    db.balancer
  elif level == -2:
    nil
  else:
    raiseAssert "Unknown level " & $level


# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
