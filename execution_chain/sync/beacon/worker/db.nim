# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronicles, chronos],
  pkg/eth/[common, rlp],
  pkg/stew/[interval_set, sorted_set],
  pkg/results,
  "../../.."/[common, core/chain, db/storage_types],
  ../worker_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbHeadersStash*(
    ctx: BeaconCtxRef;
    first: BlockNumber;
    revBlobs: openArray[seq[byte]];
    info: static[string];
      ) =
  ## Temporarily store header chain to persistent db (oblivious of the chain
  ## layout.) The headers should not be stashed if they are imepreted and
  ## executed on the database, already.
  ##
  ## The `revBlobs[]` arguments are passed in reverse order so that block
  ## numbers apply as
  ## ::
  ##    #first     -- revBlobs[^1]
  ##    #(first+1) -- revBlobs[^2]
  ##    ..
  ##
  let
    c = ctx.pool.chain
    last = first + revBlobs.len.uint64 - 1
  for n,data in revBlobs:
    let key = beaconHeaderKey(last - n.uint64)
    c.fcKvtPut(key.toOpenArray, data)
  c.fcKvtPersist()

proc dbHeaderPeek*(ctx: BeaconCtxRef; num: BlockNumber): Opt[Header] =
  ## Retrieve some stashed header.
  # Use persistent storage
  let
    key = beaconHeaderKey(num)
    rc = ctx.pool.chain.fcKvtGet(key.toOpenArray)
  if rc.isOk:
    try:
      return ok(rlp.decode(rc.value, Header))
    except RlpError:
      discard
  err()

proc dbHeaderParentHash*(ctx: BeaconCtxRef; num: BlockNumber): Opt[Hash32] =
  ## Retrieve some stashed parent hash.
  ok (? ctx.dbHeaderPeek num).parentHash

proc dbHeaderUnstash*(ctx: BeaconCtxRef; bn: BlockNumber) =
  ## Remove header from temporary DB list
  ctx.pool.chain.fcKvtDel(beaconHeaderKey(bn).toOpenArray)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
