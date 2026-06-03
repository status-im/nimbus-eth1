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
  pkg/[chronicles, eth/trie/nibbles, stew/byteutils],
  ./[session_analyse_desc, session_analyse_iter, session_analyse_recur],
  ../[mpt, worker_desc]

export
  AttType,
  WalkStats

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc clearDnglAcc(db: MptAsmRef, info: static[string]): Opt[void] =
  db.clearAccDnglKvt().isOkOr:
    chronicles.`error` info & ": Cannot reset dangling cache", `error`=error
    return err()
  ok()

proc clearDnglSto(db: MptAsmRef, info: static[string]): Opt[void] =
  db.clearStoDnglKvt().isOkOr:
    chronicles.`error` info & ": Cannot reset slots cache", `error`=error
    return err()
  ok()

proc clearDnglCode(db: MptAsmRef, info: static[string]): Opt[void] =
  db.clearCodeDnglKvt().isOkOr:
    chronicles.`error` info & ": Cannot reset receipts cache", `error`=error
    return err()
  ok()

# -----------------

proc blindDnglCB(key, path: openArray[byte]) =
  discard

proc getDnglAccCB(
    db: MptAsmRef;
    err: ptr int;
    info: static[string];
      ): OnDanglingCB =
  proc(root: Hash32, key, path: openArray[byte]) =
    db.putAccDnglKvt(key, path).isOkOr:
      error info & ": Error caching dangling account links",
        key=key.toHex, path=path.toHex, `error`=error
      err[].inc

proc getDnglStoCB(
    db: MptAsmRef;
    err: ptr int;
    info: static[string];
      ): OnDanglingCB =
  proc(root: Hash32, key, path: openArray[byte]) =
    db.putStoDnglKvt(root, key, path).isOkOr:
      error info & ": Error caching dangling slot links",
        key=key.toHex, path=path.toHex, `error`=error
      err[].inc

proc getDnglCodeCB(
    db: MptAsmRef;
    err: ptr int;
    info: static[string];
      ): OnDanglingCB =
  proc(root: Hash32, key, path: openArray[byte]) =
    db.putCodeDnglKvt(key, path).isOkOr:
      error info & ": Error caching dangling slot links",
        key=key.toHex, path=path.toHex, `error`=error
      err[].inc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionAnalyseFullTrie*(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Traverse the MPT and register all dangling links in the `*DnaglKvt`
  ## tables.
  ##
  var bodyRc = Result[WalkStats,AttType].err(EClearError)
  block body:
    let db = ctx.pool.mptAsm
    db.clearDnglAcc(info).isOkOr:
      break body
    db.clearDnglSto(info).isOkOr:
      break body
    db.clearDnglCode(info).isOkOr:
      break body

    var
      nPutErrors = 0
    let
      onDnglAccCB = db.getDnglAccCB(addr nPutErrors, info)
      onDnglStoCB = db.getDnglStoCB(addr nPutErrors, info)
      onDnglCodeCB = db.getDnglCodeCB(addr nPutErrors, info)

    bodyRc = typeof(bodyRc).err(EPutError)
    var stats = ctx.sessionAnalyseTrieIter(
                  onDnglAcc = onDnglAccCB,
                  onDnglSto = onDnglStoCB,
                  onMissSto = onDnglStoCB,
                  onMissCode = onDnglCodeCB,
                  accAndStoOk = true,
                  info).valueOr:
      if nPutErrors == 0:
        bodyRc = typeof(bodyRc).err(error)
      break body
    bodyRc = typeof(bodyRc).ok(move stats)
  bodyRc

template sessionAnalyseAccounts*(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Traverse the accounting MPT and register dangling links in the
  ## `AccDnglKvt` table.
  ##
  ## This function is used for debugging or testing, only. It can be used
  ## as a *slow* alternative and control function to the incremental dangling
  ## links bookkeeping approach of the `session_mktrie` module.
  ##
  ## It will go away, evenually..
  ##
  var bodyRc = Result[WalkStats,AttType].err(EClearError)
  block body:
    let db = ctx.pool.mptAsm
    db.clearDnglAcc(info).isOkOr:
      break body

    var nPutErrors = 0
    let onDanglingCB = db.getDnglAccCB(addr nPutErrors, info)

    bodyRc = typeof(bodyRc).err(EPutError)
    var stats = ctx.sessionAnalyseTrieIter(
                  onDnglAcc = onDanglingCB,
                  onDnglSto = blindDnglCB,
                  onMissSto = onDanglingCB,
                  onMissCode = onDanglingCB,
                  accAndStoOk = false,
                  info).valueOr:
      if nPutErrors == 0:
        bodyRc = typeof(bodyRc).err(error)
      break body
    bodyRc = typeof(bodyRc).ok(move stats)
  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
