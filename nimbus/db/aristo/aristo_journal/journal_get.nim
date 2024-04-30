# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/options,
  eth/common,
  results,
  ".."/[aristo_desc, aristo_desc/desc_backend],
  ./journal_scheduler

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc journalGetInx*(
    be: BackendRef;
    fid = none(FilterID);
    earlierOK = false;
      ): Result[JournalInx,AristoError] =
  ## If there is some argument `fid`, find the filter on the journal with ID
  ## not larger than `fid` (i e. the resulting filter must not be more recent.)
  ##
  ## If the argument `earlierOK` is passed `false`, the function succeeds only
  ## if the filter ID of the returned filter is equal to the argument `fid`.
  ##
  ## In case that there is no argument `fid`, the filter with the smallest
  ## filter ID (i.e. the oldest filter) is returned. here, the argument
  ## `earlierOK` is ignored.
  ##
  if be.journal.isNil:
    return err(FilQuSchedDisabled)

  var cache = (QueueID(0),FilterRef(nil))  # Avoids double lookup for last entry
  proc qid2fid(qid: QueueID): Result[FilterID,void] =
    if qid == cache[0]:                    # Avoids double lookup for last entry
      return ok cache[1].fid
    let fil = be.getFilFn(qid).valueOr:
      return err()
    cache = (qid,fil)
    ok fil.fid

  let qid = block:
    if fid.isNone:
      # Get oldest filter
      be.journal[^1]
    else:
      # Find filter with ID not smaller than `fid`
      be.journal.le(fid.unsafeGet, qid2fid, forceEQ = not earlierOK)

  if not qid.isValid:
    return err(FilFilterNotFound)

  var fip: JournalInx
  fip.fil = block:
    if cache[0] == qid:
      cache[1]
    else:
      be.getFilFn(qid).valueOr:
        return err(error)

  fip.inx = be.journal[qid]
  if fip.inx < 0:
    return err(FilInxByQidFailed)

  ok fip


proc journalGetOverlap*(
    be: BackendRef;
    filter: FilterRef;
      ): int =
  ## This function will find the overlap of an argument `filter` which is
  ## composed by some recent filter slots from the journal.
  ##
  ## The function returns the number of most recent journal filters that are
  ## reverted by the argument `filter`. This requires that `src`, `trg`, and
  ## `fid` of the argument `filter` is properly calculated (e.g. using
  ## `journalOpsFetchSlots()`.)
  ##
  # Check against the top-fifo entry.
  let qid = be.journal[0]
  if not qid.isValid:
    return 0

  let top = be.getFilFn(qid).valueOr:
    return 0

  # The `filter` must match the `top`
  if filter.src != top.src:
    return 0

  # Does the filter revert the fitst entry?
  if filter.trg == top.trg:
    return 1

  # Check against some stored filter IDs
  if filter.isValid:
    let fp = be.journalGetInx(some(filter.fid), earlierOK=true).valueOr:
      return 0
    if filter.trg == fp.fil.trg:
      return 1 + fp.inx

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
