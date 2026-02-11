# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronicles, chronos],
  ../[helpers, mpt, state_db, worker_desc]

import
  ../debug

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

proc accountRequeue*(ctx: SnapCtxRef; info: static[string]): bool =
  ## Process stashed accounts. Validate raw packet and store it as a
  ## list of `(key,node)` pairs.
  ##
  ## The function returns `true` if some accounts coud be re-queued,
  ## successfully or not.
  ##
  let
    adb = ctx.pool.mptAsm

  for w in adb.walkRawAccPkg():
    # Validate packet
    let
      then = Moment.now()
      mpt = block:
        let rc = w.root.validate(w.start, w.packet)
        block cleanUp:
          adb.delRawAccPkg(w.root, w.start).isOkOr:
            trace info & ": error deleting packet", root=w.root.toStr,
              iv=(w.start,w.limit).to(float).toStr,
              nAccounts=w.packet.accounts.len, nProof=w.packet.proof.len,
              `error`=error
          break cleanUp

        if rc.isErr:
          # Mark peer that produced that unusable headers list as a zombie
          let srcPeer = ctx.getSyncPeer w.peerID
          if not srcPeer.isNil:
            srcPeer.only.nErrors.apply.acc = nProcAccountErrThreshold + 1

          # Done for now
          ctx.pool.mptEla += (Moment.now() - then)
          debug info & ": accounts validation failed", root=w.root.toStr,
            iv=(w.start,w.limit).to(float).toStr,
            nAccounts=w.packet.accounts.len, nProof=w.packet.proof.len,
            elaSum=ctx.pool.mptEla.toStr
          doAssert dumpAccFailFile.dumpToFile(w.root, w.start, w.packet)
          return true                               # failed, but did something

        rc.value

    # Store downloaded and expanded partial accounts data trie
    block:
      let rc = adb.putMptAccounts(w.root, w.start, mpt.pairs)
      ctx.pool.mptEla += (Moment.now() - then)

      if rc.isErr:
        debug info & ": caching accounts failed", root=w.root.toStr,
          iv=(w.start,w.limit).to(float).toStr,
          nAccounts=w.packet.accounts.len, nProof=w.packet.proof.len,
          elaSum=ctx.pool.mptEla.toStr, error=rc.error
        doAssert dumpAccFailFile.dumpToFile(w.root, w.start, w.packet)
        return true                                 # failed, but did something

    # Successfully stored
    debug info & ": accounts stored", root=w.root.toStr,
      iv=(w.start,w.limit).to(float).toStr,
      nAccounts=w.packet.accounts.len, nProof=w.packet.proof.len,
      elaSum=ctx.pool.mptEla.toStr
    return true

  # false                                           # no serious work done

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
