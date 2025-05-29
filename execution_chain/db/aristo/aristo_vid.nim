# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Handle vertex IDs on the layered Aristo DB delta architecture
## =============================================================
##
{.push raises: [].}

import ./aristo_desc

export aristo_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc staticVid*(accPath: NibblesBuf, level: int): VertexID =
  ## Compute a static vid based on the initial nibbles of the given path. The
  ## vid assignment is done in a breadth-first manner where numerically, each
  ## level follows the previous one meaning that the root occupies VertexID(1),
  ## its direct children 2-17 etc.
  ##
  ## The level-based sorting ensures that children of each level are colocated
  ## on disk reducing the number of disk reads needed to load all children of a
  ## node which is useful when computing hash keys.
  if level == 0:
    STATE_ROOT_VID
  else:
    var v = uint64(STATE_ROOT_VID)
    for i in 0 ..< level:
      v += 1'u64 shl (i * 4)

      v += uint64(accPath[i]) shl ((level - i - 1) * 4)

    VertexID(v)

proc vidFetch*(db: AristoTxRef, n = 1): VertexID =
  ## Fetch next vertex ID.
  ##
  if db.vTop == 0:
    db.vTop = VertexID(FIRST_DYNAMIC_VID - 1)
  var ret = db.vTop
  ret.inc
  db.vTop.inc(n)
  ret

proc accVidFetch*(db: AristoTxRef, path: NibblesBuf, n = 1): VertexID =
  ## Fetch next vertex ID.
  ##
  let res =
    if path.len <= STATIC_VID_LEVELS:
      path.staticVid(path.len)
    else:
      db.vidFetch(n)
  res

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
