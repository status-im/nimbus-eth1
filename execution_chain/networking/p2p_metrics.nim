# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  metrics

export
  metrics

declarePublicGauge rlpx_connected_peers, "Number of connected peers in the pool"

declarePublicCounter rlpx_connect_success, "Number of successfull rlpx connects", labels = ["discversion"]

declarePublicCounter rlpx_connect_failure,
  "Number of rlpx connects that failed", labels = ["reason", "discversion"]

declarePublicCounter rlpx_accept_success, "Number of successful rlpx accepted peers"

declarePublicCounter rlpx_accept_failure,
  "Number of rlpx accept attempts that failed", labels = ["reason"]
