#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ../worker_desc,
  ./play/[play_desc, play_full_sync, play_prep_full, play_snap_sync]

export
  PlaySyncSpecs,
  playSyncSpecs,
  `playMode=`

proc playInit*(desc: var SnapSyncSpecs) =
  ## Set up sync mode specs table. This cannot be done at compile time.
  desc.tab[SnapSyncMode] = playSnapSyncSpecs()
  desc.tab[PreFullSyncMode] = playPrepFullSpecs()
  desc.tab[FullSyncMode] = playFullSyncSpecs()

# End
