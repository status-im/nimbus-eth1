#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ../worker_desc,
  ./play/[play_desc, play_full_sync, play_snap_sync]

export
  PlaySyncSpecs,
  playMethod

proc playSetup*(ctx: SnapCtxRef) =
  ## Set up sync mode specs table. This cannot be done at compile time.
  ctx.pool.syncMode.tab[SnapSyncMode] = playSnapSyncSpecs()
  ctx.pool.syncMode.tab[FullSyncMode] = playFullSyncSpecs()

proc playRelease*(ctx: SnapCtxRef) =
  discard

# End
