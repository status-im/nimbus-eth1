#!/usr/bin/env bash

# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.



# NOTE!
# these scripts are for development purposes only not meant to be used on official docs-
# to be removed before deployment

exec build/nimbus_unified \
--network=holesky \
--data-dir="build/data/shared_holesky_0" \
--tcp-port=9000 \
--udp-port=9000 \
--rest \
--rest-port=5052 \
--metrics \
"$@"
# --el=http://127.0.0.1:8551 \
# --jwt-secret="/tmp/jwtsecret" \
# --web3-url=http://127.0.0.1:8551
# --log-level=TRACE \


# exec build/nimbus_unified \
# --network=mainnet \
# --data-dir=build/data/shared_mainnet_0 \
# --engine-api \
# --tcp-port=9000 \
# --udp-port=9000 \
# --rest \
# --rest-port=5052 \
# --metrics \
# "$@"
# --log-level=TRACE \
# --el=http://127.0.0.1:8551 \
# --jwt-secret="/tmp/jwtsecret" \
# --web3-url=http://127.0.0.1:8551
