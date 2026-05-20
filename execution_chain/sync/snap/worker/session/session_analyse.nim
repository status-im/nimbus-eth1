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
  ./[session_analyse_iter, session_analyse_recur],
  ../worker_desc

export
  session_analyse_iter,
  session_analyse_recur

template sessionAnalyseFullTrie*(ctx: SnapCtxRef, info: static[string]): auto =
  sessionAnalyseTrieIter(ctx, accAndStoOk=true, info)

template sessionAnalyseAccTrie*(ctx: SnapCtxRef, info: static[string]): auto =
  sessionAnalyseTrieIter(ctx, accAndStoOk=false, info)

# End
