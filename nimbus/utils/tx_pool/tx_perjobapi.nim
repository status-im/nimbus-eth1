# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool, Per-Job API For Testing
## =========================================

import
  ../tx_pool,
  ./tx_job,
  eth/keys,
  stew/results

# ------------------------------------------------------------------------------
# Public functions, per-job API -- temporary for testing
# ------------------------------------------------------------------------------

proc pjaUpdateStaged*(xp: TxPoolRef; force = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Update staged bucket
  discard xp.job(TxJobDataRef(
    kind:     txJobUpdateStaged,
    updateStagedArgs: (
      force:  force)))

proc pjaUpdatePacked*(xp: TxPoolRef; force = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Update packed bucket
  discard xp.job(TxJobDataRef(
    kind:     txJobUpdatePacked,
    updatePackedArgs: (
      force:  force)))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
