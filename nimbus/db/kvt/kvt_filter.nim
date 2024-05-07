# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Filter management
## ===========================
##

import
  std/[sequtils, tables],
  results,
  ./kvt_desc,
  ./kvt_desc/desc_backend,
  ./kvt_filter/[filter_merge, filter_reverse]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc filterMerge*(
    db: KvtDbRef;                      # Database
    filter: LayerDeltaRef;             # Filter to apply to database
      ) =
  ## Merge the argument `filter` into the read-only filter layer. Note that
  ## this function has no control of the filter source. Having merged the
  ## argument `filter`, all the `top` and `stack` layers should be cleared.
  ##
  db.merge(filter, db.roFilter)


proc filterUpdateOk*(db: KvtDbRef): bool =
  ## Check whether the read-only filter can be merged into the backend
  not db.backend.isNil and db.isCentre


proc filterUpdate*(
    db: KvtDbRef;                      # Database
    reCentreOk = false;
      ): Result[void,KvtError] =
  ## Resolve (i.e. move) the backend filter into the physical backend database.
  ##
  ## This needs write permission on the backend DB for the argument `db`
  ## descriptor (see the function `aristo_desc.isCentre()`.) With the argument
  ## flag `reCentreOk` passed `true`, write permission will be temporarily
  ## acquired when needed.
  ##
  ## Other non-centre descriptors are updated so there is no visible database
  ## change for these descriptors.
  ##
  let be = db.backend
  if be.isNil:
    return err(FilBackendMissing)

  # Blind or missing filter
  if db.roFilter.isNil:
    return ok()

  # Make sure that the argument `db` is at the centre so the backend is in
  # read-write mode for this peer.
  let parent = db.getCentre
  if db != parent:
    if not reCentreOk:
      return err(FilBackendRoMode)
    db.reCentre
  # Always re-centre to `parent` (in case `reCentreOk` was set)
  defer: parent.reCentre

  # Store structural single trie entries
  let writeBatch = be.putBegFn()
  be.putKvpFn(writeBatch, db.roFilter.sTab.pairs.toSeq)
  ? be.putEndFn writeBatch

  # Update peer filter balance.
  let rev = db.filterReverse db.roFilter
  for w in db.forked:
    db.merge(rev, w.roFilter)

  db.roFilter = LayerDeltaRef(nil)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
