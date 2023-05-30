# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Read vertex recorfd on the layered Aristo DB delta architecture
## ===============================================================

{.push raises: [].}

import
  std/tables,
  stew/results,
  "."/[aristo_desc, aristo_error]

type
  VidVtxPair* = object
    vid*: VertexID                 ## Table lookup vertex ID (if any)
    vtx*: VertexRef                ## Reference to vertex

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getVtxCascaded*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[VertexRef,AristoError] =
  ## Cascaded lookup for data record down the transaction cascade. This
  ## function will return a potential error code from the backend (if any).
  db.sTab.withValue(vid, vtxPtr):
    return ok vtxPtr[]

  # Down the rabbit hole of transaction layers
  var lDb = db
  while lDb.cascaded:
    lDb = lDb.stack
    lDb.sTab.withValue(vid, vtxPtr):
      return ok vtxPtr[]

  let be = lDb.backend
  if not be.isNil:
    return be.getVtxFn vid

  err(GetVtxNotFound)

proc getVtxCascaded*(
    db: AristoDbRef;
    tag: NodeTag;
      ): Result[VidVtxPair,AristoError] =
  ## Cascaded lookup for data record down the transaction cascade using
  ## the Patricia path.
  db.lTab.withValue(tag, vidPtr):
    db.sTab.withValue(vidPtr[], vtxPtr):
      return ok VidVtxPair(vid: vidPtr[], vtx: vtxPtr[])
    return err(GetTagNotFound)

  # Down the rabbit hole of transaction layers
  var lDb = db
  while lDb.cascaded:
    lDb = lDb.stack
    lDb.lTab.withValue(tag, vidPtr):
      lDb.sTab.withValue(vidPtr[], vtxPtr):
        return ok VidVtxPair(vid: vidPtr[], vtx: vtxPtr[])
      return err(GetTagNotFound)

  err(GetTagNotFound)

proc getVtx*(db: AristoDbRef; vid: VertexID): VertexRef =
  ## Variant of `getVtxCascaded()` with returning `nil` on error ignoring the
  ## error type information.
  let rc = db.getVtxCascaded vid
  if rc.isOk:
    return rc.value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
