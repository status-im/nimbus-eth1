#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ../worker_desc,
  ./pass/[pass_desc, pass_full, pass_snap]

export
  PassActorRef,
  passActor

proc passSetup*(ctx: SnapCtxRef) =
  ## Set up sync mode specs table. This cannot be done at compile time.
  ctx.pool.syncMode.tab[SnapSyncMode] = passSnap()
  ctx.pool.syncMode.tab[FullSyncMode] = passFull()

proc passRelease*(ctx: SnapCtxRef) =
  discard

# End
