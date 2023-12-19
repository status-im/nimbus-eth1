# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/tables,
  eth/common,
  ./kvt_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc layersCc*(db: KvtDbRef; level = high(int)): LayerRef =
  ## Provide a collapsed copy of layers up to a particular transaction level.
  ## If the `level` argument is too large, the maximum transaction level is
  ## returned. For the result layer, the `txUid` value set to `0`.
  let level = min(level, db.stack.len)

  # Merge stack into its bottom layer
  if level <= 0 and db.stack.len == 0:
    result = LayerRef(delta: LayerDelta(sTab: db.top.delta.sTab))
  else:
    # now: 0 < level <= db.stack.len
    result = LayerRef(delta: LayerDelta(sTab: db.stack[0].delta.sTab))

    for n in 1 ..< level:
      for (key,val) in db.stack[n].delta.sTab.pairs:
        result.delta.sTab[key] = val

    # Merge top layer if needed
    if level == db.stack.len:
      for (key,val) in db.top.delta.sTab.pairs:
        result.delta.sTab[key] = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
