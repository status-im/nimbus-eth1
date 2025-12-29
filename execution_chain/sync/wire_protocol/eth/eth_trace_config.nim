# nimbus-execution-client
#
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

const
  # Some static noisy settings for `eth` debugging
  trEthTracePacketsOk* = true
    ## `trace` log each sync network message.
  trEthTraceGossipOk* = false
    ## `trace` log each sync network message.
  trEthTraceHandshakesOk* = true
    ## `trace` log each network handshake message.

# End
