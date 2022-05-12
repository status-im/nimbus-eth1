# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  ./protocol/eth66 as proto_eth,
  ./protocol/snap1 as proto_snap

export
  proto_eth,
  proto_snap

type
  eth* = eth66
  snap* = snap1

# End
