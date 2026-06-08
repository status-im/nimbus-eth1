# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  ./session_analyse/[analyse_desc, analyse_iter, analyse_recur],
  ../worker_desc

export
  AttType,
  WalkStats

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionAnalyseFullTrie*(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Traverse the MPT and register all dangling links in the `*DanglKvt`
  ## tables.
  ##
  ctx.sessionAnalyseTrieIter(info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
