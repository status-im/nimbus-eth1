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
  pkg/[chronicles, eth/common],
  pkg/stew/[byteutils, interval_set],
  ./[helpers, mpt, worker_desc],
  ./state_forward/[forward_apply, forward_calc]

logScope:
  topics = "snap sync"

const
  VerifyAgainstCoreDb = false
    ## Do a secondary `CoreDb` import when verifying state roots and
    ## compare it against the state root compiled for the flat tables.
    ##
    ## Note that this feature needs the debug syb-modules which are
    ## only available in a test environment.
    ##
    ## This constant `VerifyAgainstCoreDb` is temporarily used
    ## and will go away.

when VerifyAgainstCoreDb:
  import ./import_coredb

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc stateForwardVerify*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[void] =
  ## Calculate the flat tables state root and compare it aganst the state
  ## root stored in the corresponding state header.
  ##
  ## This function is for testing only.
  ##
  ## It has potentally a huge memory foot print as the state root is
  ## calculated by assembling MPTs in memory.
  ##
  let
    db = ctx.pool.cacheDB
    status = ?db.getAccMissingIntv(info)
    cacheRc = ?db.calcStateRoot(info)
    header = ?db.getHeader(status.number, info)

  when VerifyAgainstCoreDb:
    let tx = CoreDb2Ref.init(ctx, clean=true)
    defer: tx.destroy()

    let
      txStats = ?tx.importFlat(db, info)
      txStateRoot = ?tx.fetchStateRoot(info)

    if cacheRc.stateRoot != txStateRoot:
      error info & ": Oops, state roots differ", number=status.number,
        cacheStats=cacheRc.stats, txStats, stateRoot=cacheRc.stateRoot,
        txStateRoot=txStateRoot.toStr
      return err()

  if cacheRc.stateRoot != header.stateRoot:
    error info & ": Oops, state root mismatch", number=status.number,
      cacheStats=cacheRc.stats, stateRoot=cacheRc.stateRoot,
      expected=header.stateRoot.toStr
    return err()

  ok()

proc stateForward*(
    ctx: SnapCtxRef;
    info: static[string];
    nBalsMax = high(uint);
      ): Opt[void] =
  ## Apply stored BALs to the downloaded flat account and storage tables.
  ## If successful, the block number of the last state is returned.
  ##
  ## The maximal number of BAs to apply can be passed as argument `nBalsMax`.
  ## In that case, the function can be called repeatedly until the BALs
  ## are exhausted. The latter can be detected if the return value stays
  ## the same.
  ##
  let
    db = ctx.pool.cacheDB
    pivotNum = (?db.getAccMissingIntv(info)).number

  var number = pivotNum
  template dist: untyped = (number-pivotNum)

  while true:
    if nBalsMax <= dist:
      trace info & ": BALs applied", pivotNum, number, dist
      break
    number.inc
    let bal = db.getBal(number, info).valueOr:
      number.dec
      trace info & ": BALs exhausted", pivotNum, number, dist
      break

    for w in bal[]:
      ctx.applyAccountChanges(w, info).isOkOr:
        error info & ": Error applying BAL account changes", pivotNum, number,
          dist, accAddr=($w.address), accPath=w.address.computeAccPath.toStr
        return err()

  # Update pivot and forward block numbers if there was some progress
  if pivotNum < number:
    ?db.updAccMissingIntv(number, info)
    ctx.pool.pivotNum = number
    ctx.pool.forwardNum = number

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
