# nimbus-eth1
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sets,
  eth/common,
  ../aristo_desc

type
  PartStateRef* = ref object of RootRef
    db*: AristoTxRef
    core*: Table[VertexID,HashSet[HashKey]] # Existing vertices
    pureExt*: Table[HashKey,PrfExtension]   # On-demand node (usually hidden)
    byKey*: Table[HashKey,RootedVertexID]   # All keys, instead of `kMap[]`
    byVid*: Table[VertexID,HashKey]         # On demand for `PartStateCtx`
    changed*: HashSet[HashKey]              # Changed perimeter vertices

  PartStateMode* = enum
    AutomaticPayload
    ForceGenericPayload
    ForceAccOrStoPayload

  PartStateCtx* = ref object
    ps*: PartStateRef
    location*: RootedVertexID
    nibble*: int
    fromVid*: VertexID

  # -------------------

  PrfExtension* = ref object
    xPfx*: NibblesBuf
    xLink*: HashKey

  PrfBackLinks* = ref object
    chains*: seq[seq[HashKey]]
    links*: Table[HashKey,HashKey]

  PrfType* = enum
    ignore = 0
    isError
    isExtension                # `PrfNode` only
    isAccount                  # `PrfPayload` only
    isStoValue                 # `PrfPayload` only

  PrfNode* = ref object of NodeRef
    prfType*: PrfType          # Avoid checking all branches if `isExtension`
    error*: AristoError        # Used for error signalling in RLP decoder

  PrfPayload* = object
    case prfType*: PrfType
    of isAccount:
      acc*: Account
    of isStoValue:
      num*: UInt256
    else:
      error*: AristoError

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc init*(T: type PartStateRef; db: AristoTxRef): T =
  ## Constructor for a partial database.
  T(db: db)

# -----------

proc `[]=`*(ps: PartStateRef; key: HashKey; rvid: RootedVertexID) =
  doAssert rvid.isValid
  var mvCoreKey = false

  # Remove existing `rvid` from `byVid[]` and `core[]` tables where needed
  ps.byKey.withValue(key, rv):
    if rvid == rv[]:
      return # nothing to do

    # Key exists already, remove it from `byVid[]`
    ps.byVid.del rv.vid

    # Remove `vid` from `core[root]` list
    if rvid.root != rv.root:
      ps.core.withValue(rv.root, keys):
        if key in keys[]:
          mvCoreKey = true
          keys[].excl key
          if keys[].len == 0:
            ps.core.del rv.root

  # Add new entry
  ps.byKey[key] = rvid
  ps.byVid[rvid.vid] = key
  if mvCoreKey:
    ps.core.withValue(rvid.root, keys):
      keys[].incl key
    do: ps.core[rvid.vid] = @[key].toHashSet


proc `[]`*(ps: PartStateRef; key: HashKey): RootedVertexID =
  ps.byKey.withValue(key,rv):
    return rv[]

proc `[]`*(ps: PartStateRef; vid: VertexID): HashKey =
  ps.byVid.withValue(vid,key):
    return key[]
  VOID_HASH_KEY


proc del*(ps: PartStateRef; key: HashKey) =
  ps.byKey.withValue(key,rv):
    ps.changed.excl key
    ps.byVid.del rv.vid
    ps.byKey.del key

proc del*(ps: PartStateRef; vid: VertexID) =
  ps.byVid.withValue(vid,key):
    ps.changed.excl key[]
    ps.byKey.del key[]
    ps.byVid.del vid


proc move*(ps: PartStateRef; fromVid: VertexID; toVid: VertexID): HashKey =
  doAssert toVid.isValid
  result = VOID_HASH_KEY

  var root: VertexID
  ps.byVid.withValue(fromVid,key):
    ps.byKey.withValue(key[], rv):
      if fromVid == rv.vid:
        (result,root) = (key[], rv.root)
    do: return VOID_HASH_KEY
  do: return VOID_HASH_KEY

  ps.byKey[result] = (root,toVid)
  ps.byVid[toVid] = result
  ps.byVid.del fromVid


proc addCore*(ps: PartStateRef; root: VertexID; key: HashKey) =
  ps.core.withValue(root, keys):
    keys[].incl key
  do: ps.core[root] = @[key].toHashSet

proc delCore*(ps: PartStateRef; root: VertexID; key: HashKey) =
  ps.core.withValue(root, keys):
    if key in keys[]:
      ps.del key
      keys[].excl key
      if keys[].len == 0:
        ps.core.del root

proc isCore*(ps: PartStateRef; rvid: RootedVertexID): bool =
  ## Returns `true` if the `key` derived from `rvid` is listed in `core[]`.
  ps.core.withValue(rvid.root, keys):
    ps.byVid.withValue(rvid.vid, key):
      return (key[] in keys[])

proc isCore*(ps: PartStateRef; key: HashKey): bool =
  ## Returns `true` if `key` is listed in `core[]`,
  ps.byKey.withValue(key, rv):
    ps.core.withValue(rv.root, keys):
      return (key in keys[])

proc isCore*(ps: PartStateRef; vid: VertexID): bool =
  ## Returns `true` if the `key` derived from `vid` is listed in `core[]`.
  ps.byVid.withValue(vid, key):
    ps.byKey.withValue(key[], rv):
      ps.core.withValue(rv.root, keys):
        return (key[] in keys[])

proc isPerimeter*(ps: PartStateRef; vid: VertexID): bool =
  ## Returns `true` if `vid` is registered and neither listed in `core[]`.
  ## nor in `changed[]`.
  ps.byVid.withValue(vid, key):
    if key[] notin ps.changed and not ps.isCore(key[]):
      return true

proc isExtension*(ps: PartStateRef; vid: VertexID): bool =
  ## Returns `true` if `vid` is belongs to a pure extension node.
  ps.byVid.withValue(vid, key):
    if key[] in ps.pureExt:
      return true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
