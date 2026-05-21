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
  pkg/[chronos, chronicles, eth/trie/nibbles],
  ./[session_analyse_desc, session_analyse_iter, session_analyse_recur],
  ../[mpt, worker_desc]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionAnalyseFullTrie*(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  var bodyRc = Opt[Duration].err()
  block body:
    var ela = ctx.sessionAnalyseTrieIter(
                onDnglAcc = OnDanglingCB(nil),
                onDnglSto = OnDanglingCB(nil),
                onMissSto = OnDanglingCB(nil),
                onMissCode = OnDanglingCB(nil),
                accAndStoOk = true,
                info).valueOr:
      break body
    bodyRc = typeof(bodyRc).ok(move ela)
  bodyRc

template sessionAnalyseAccounts*(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Traverse the accounting MPT and register dangling links in the
  ## `AccDangling` table.
  ##
  var bodyRc = Result[(Duration,int),(AttType,int)].err((EOtherError,0))
  block body:
    let db = ctx.pool.mptAsm
    db.clearAccDanglingKvt().isOkOr:
      chronicles.`error` info & ": Cannot reset dangling cache", `error`=error
      bodyRc = typeof(bodyRc).err((EClearError,0))
      break body

    var (nDangl, nErrors) = (0, 0)
    proc onDanglingCB(key: seq[byte], path: NibblesBuf) =
      nDangl.inc
      db.putAccDanglingKvt(key, path.toHexPrefix(false).data()).isOkOr:
        chronicles.error info & ": Error caching dangling pivot links",
          `error`=error
        nErrors.inc

    var ela = ctx.sessionAnalyseTrieIter(
                onDnglAcc = onDanglingCB,
                onDnglSto = OnDanglingCB(nil),
                onMissSto = onDanglingCB,
                onMissCode = onDanglingCB,
                accAndStoOk = false,
                info).valueOr:
      if 0 < nErrors:
        bodyRc = typeof(bodyRc).err((EPutError,nErrors))
      else:
        bodyRc = typeof(bodyRc).err((error,nErrors))
      break body
    bodyRc = typeof(bodyRc).ok((move ela, nDangl))
  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
