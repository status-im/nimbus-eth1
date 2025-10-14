# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  ./[blocks, headers, worker_desc]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func somethingToCollectOrUnstage*(buddy: BeaconBuddyRef): bool =
  if buddy.ctx.hibernate:                        # not activated yet?
    return false
  if buddy.headersCollectOk() or                 # something on TODO list
     buddy.headersUnstageOk() or
     buddy.blocksCollectOk() or
     buddy.blocksUnstageOk():
    return true
  false

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
