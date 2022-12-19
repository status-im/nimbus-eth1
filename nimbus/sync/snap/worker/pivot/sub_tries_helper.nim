# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/sequtils,
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/interval_set,
  "../.."/[constants, range_desc, worker_desc],
  ../db/[hexary_desc, hexary_error, hexary_inspect]

{.push raises: [Defect].}

logScope:
  topics = "snap-subtrie"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Sub-trie helper " & info

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc doInspect(
    getFn: HexaryGetFn;                ## Abstract database access
    rootKey: NodeKey;                  ## Start of hexary trie
    nodes: seq[NodeSpecs];             ## Nodes with prob. dangling child links
    resumeCtx: TrieNodeStatCtxRef;     ## Resume previous inspection
     ): Result[TrieNodeStat,HexaryError]
     {.gcsafe, raises: [Defect,RlpError].} =
  ## ..
  let stats = getFn.hexaryInspectTrie(
    rootKey, nodes.mapIt(it.partialPath), resumeCtx, healInspectionBatch)

  if stats.stopped:
    return err(TrieLoopAlert)

  ok(stats)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc subTriesFromPartialPaths*(
    getFn: HexaryGetFn;                ## Abstract database access
    stateRoot: Hash256;                ## Start of hexary trie
    batch: SnapRangeBatchRef;          ## Healing data support
    nodesMissingMaxLen = high(int);    ## Max length of `nodes.missing`
      ): Future[Result[void,HexaryError]]
      {.async.} =
  ## Starting with a given set of potentially dangling account nodes
  ## `checkNodes`, this set is filtered and processed. The outcome is
  ## fed back to the vey same list `checkNodes`

  # Process might be expensive, so only a single instance is allowed to run it
  if batch.lockTriePerusal:
    return err(TrieIsLockedForPerusal)
  batch.lockTriePerusal = true

  let
    rootKey = stateRoot.to(NodeKey)
  var
    error: HexaryError
    count = 0                                      # for logging
    start = Moment.now()                           # for logging

  block errorWhenOutside:
    try:
      while batch.nodes.missing.len < nodesMissingMaxLen:
        # Inspect hexary trie for dangling nodes
        let rc = getFn.doInspect(rootKey, batch.nodes.check, batch.resumeCtx)
        if rc.isErr:
          error = rc.error
          break errorWhenOutside

        count.inc

        # Update context for async threading environment
        batch.resumeCtx = rc.value.resumeCtx
        batch.nodes.check.setLen(0)

        # Collect result
        batch.nodes.missing = batch.nodes.missing & rc.value.dangling

        # Done unless there is some resumption context
        if rc.value.resumeCtx.isNil:
          break

        when extraTraceMessages:
          trace logTxt "inspection wait", count,
            elapsed=(Moment.now()-start),
            sleep=healInspectionBatchWaitNanoSecs,
            nodesMissingLen=batch.nodes.missing.len, nodesMissingMaxLen,
            resumeCtxLen = batch.resumeCtx.hddCtx.len

        # Allow async task switch and continue. Note that some other task might
        # steal some of the `nodes.missing` var argument.
        await sleepAsync healInspectionBatchWaitNanoSecs.nanoseconds

      batch.lockTriePerusal = false
      return ok()

    except RlpError:
      error = RlpEncoding

  batch.nodes.missing = batch.nodes.missing & batch.resumeCtx.to(seq[NodeSpecs])
  batch.resumeCtx = nil

  batch.lockTriePerusal = false
  return err(error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

