# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/tables,
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get]

type
  LayerStateRoot* = tuple
    ## Helper structure for analysing state roots.
    be: Hash256                    ## Backend state root
    fg: Hash256                    ## Layer or filter implied state root

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getLayerStateRoots*(
    db: AristoDbRef;
    delta: LayerDeltaRef;
    chunkedMpt: bool;
      ): Result[LayerStateRoot,AristoError] =
  ## Get the Merkle hash key for target state root to arrive at after this
  ## reverse filter was applied.
  ##
  var spr: LayerStateRoot

  let sprBeKey = block:
    let rc = db.getKeyBE VertexID(1)
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err(rc.error)
  spr.be = sprBeKey.to(Hash256)

  spr.fg = block:
    let key = delta.kMap.getOrVoid VertexID(1)
    if key.isValid:
      key.to(Hash256)
    else:
      EMPTY_ROOT_HASH
  if spr.fg.isValid:
    return ok(spr)

  if not delta.kMap.hasKey(VertexID(1)) and
     not delta.sTab.hasKey(VertexID(1)):
    # This layer is unusable, need both: vertex and key
    return err(FilPrettyPointlessLayer)
  elif not delta.sTab.getOrVoid(VertexID(1)).isValid:
    # Root key and vertex has been deleted
    return ok(spr)

  if chunkedMpt:
    if sprBeKey == delta.kMap.getOrVoid VertexID(1):
      spr.fg = spr.be
      return ok(spr)

  if delta.sTab.len == 0 and
     delta.kMap.len == 0:
    return err(FilPrettyPointlessLayer)

  err(FilStateRootMismatch)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
