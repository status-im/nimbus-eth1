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
func mergeAndReset*(tgt, src: var auto) =
  tgt = move(src)

func mergeAndReset*(tgt, src: var seq) =
  mixin mergeAndReset
  if tgt.len == 0:
    swap(tgt, src)
  else:
    let tlen = tgt.len
    tgt.setLen(tgt.len + src.len)
    for i, sv in src.mpairs():
      mergeAndReset(tgt[tlen + i], sv)
    src.reset()

func mergeAndReset*(tgt, src: var HashSet) =
  mixin mergeAndReset
  if tgt.len == 0:
    swap(tgt, src)
  else:
    for sv in src.items():
      tgt.incl(sv)
    src.reset()

func mergeAndReset*(tgt, src: var Table) =
  mixin mergeAndReset
  if tgt.len == 0:
    swap(tgt, src)
  else:
    for k, sv in src.mpairs():
      tgt.withValue(k, tv):
        mergeAndReset(tv[], sv)
      do:
        tgt[k] = move(sv)
    src.reset()
