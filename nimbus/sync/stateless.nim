# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/[common, p2p],
  chronicles,
  chronos,
  stew/[interval_set, sorted_set],
  "."/[sync_desc, sync_sched, protocol]

logScope:
  topics = "stateless-sync"

type
  StatelessSyncRef* = ref object
    # FIXME-Adam: what needs to go in here?

    
# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(T: type StatelessSyncRef): T =
  new result


proc start*(ctx: StatelessSyncRef) =
  # FIXME-Adam: What do I need here, if anything?
  discard

proc stop*(ctx: StatelessSyncRef) =
  discard
