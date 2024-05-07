# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction stow/save helper
## =========================================
##
{.push raises: [].}

import
  std/options,
  results,
  ".."/[aristo_desc, aristo_get, aristo_journal, aristo_layers, aristo_hashify]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txStow*(
    db: AristoDbRef;                  # Database
    nxtFid: Option[FilterID];         # Next filter ID (zero is OK)
    persistent: bool;                 # Stage only unless `true`
    chunkedMpt: bool;                 # Partial data (e.g. from `snap`)
      ): Result[void,AristoError] =
  ## Worker for `stow()` and `persist()` variants.
  ##
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)
  if persistent and not db.journalUpdateOk():
    return err(TxBackendNotWritable)

  # Update Merkle hashes (unless disabled)
  db.hashify().isOkOr:
    return err(error[1])

  let fwd = db.journalFwdFilter(db.top, chunkedMpt).valueOr:
    return err(error[1])

  if fwd.isValid:
    # Move/merge `top` layer onto `roFilter`
    db.journalMerge(fwd).isOkOr:
      return err(error[1])

    # Special treatment for `snap` proofs (aka `chunkedMpt`)
    let final =
      if chunkedMpt: LayerFinalRef(fRpp: db.top.final.fRpp)
      else: LayerFinalRef()

    # New empty top layer (probably with `snap` proofs and `vGen` carry over)
    db.top = LayerRef(
      delta: LayerDeltaRef(),
      final: final)
    if db.roFilter.isValid:
      db.top.final.vGen = db.roFilter.vGen
    else:
      let rc = db.getIdgUbe()
      if rc.isOk:
        db.top.final.vGen = rc.value
      else:
        # It is OK if there was no `Idg`. Otherwise something serious happened
        # and there is no way to recover easily.
        doAssert rc.error == GetIdgNotFound

  if persistent:
    # Merge/move `roFilter` into persistent tables
    ? db.journalUpdate nxtFid

  # Special treatment for `snap` proofs (aka `chunkedMpt`)
  let final =
    if chunkedMpt: LayerFinalRef(vGen: db.vGen, fRpp: db.top.final.fRpp)
    else: LayerFinalRef(vGen: db.vGen)

  # New empty top layer (probably with `snap` proofs carry over)
  db.top = LayerRef(
    delta: LayerDeltaRef(),
    final: final,
    txUid: db.top.txUid)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
