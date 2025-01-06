#!/usr/bin/env bash

# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.


#TODO: a lot to do on this exec script. improve/refactor as the project proceeds

#Execution
# tbd
#Consensus
# tbd
#unified
exec build/nimbus_unified \
--network=holesky \
--data-dir="build/data/shared_holesky_0" \
# --network=mainnet \
# --data-dir=build/data/shared_mainnet_0 \
--tcp-port=9000 \
--udp-port=9000 \
--log-level=TRACE \
--rest \
--rest-port=5052
