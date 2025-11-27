# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ./worker/worker_desc,
  ../[sync_desc, sync_sched]

export
  sync_desc, worker_desc

type
  SnapSyncConfigHook* = proc(desc: SnapSyncRef) {.gcsafe, raises: [].}
    ## Conditional configuration request hook

  SnapSyncRef* = ref object of RunnerSyncRef[SnapCtxData,SnapPeerData]
    ## Instance descriptor, extends scheduler object
    lazyConfigHook*: SnapSyncConfigHook

# End
