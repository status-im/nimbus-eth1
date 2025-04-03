# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, sets]

# Utilities for merging source data into a target taking care to move data and
# leave the source empty

type MoveType = seq[byte]|ref
  # Types that we simply move over when merging (instead of trying to join their
  # elements)

func mergeAndDiscard*(tgt, src: var MoveType) =
  # The `src` item will be discarded after the merge, hence it can either be
  # reset for reuse or left as is, whichever is more efficient
  tgt = move(src)

func mergeAndDiscard*(tgt, src: var HashSet) =
  if tgt.len == 0:
    swap(tgt, src)
  else:
    for sv in src.items():
      tgt.incl(sv)

func mergeAndReset*(tgt, src: var HashSet) =
  mergeAndDiscard(tgt, src)
  src.reset()

func mergeAndReset*(tgt, src: var Table) =
  mixin mergeAndDiscard
  if tgt.len == 0:
    swap(tgt, src)
  else:
    for k, sv in src.mpairs():
      tgt.withValue(k, tv):
        mergeAndDiscard(tv[], sv)
      do:
        tgt[k] = move(sv)
    src.reset()
