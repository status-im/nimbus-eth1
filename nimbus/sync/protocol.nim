# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Provision of `eth` and `snap` protocol version parameters
##
## `Eth` related parameters:
##   `eth`                   -- type symbol of default version
##   `proto_eth`             -- export of default version directives
##

{.push raises: [].}

import
  ./protocol/eth68 as proto_eth

type eth* = eth68

import
  ./protocol/snap1 as proto_snap

export
  proto_eth,
  proto_snap
