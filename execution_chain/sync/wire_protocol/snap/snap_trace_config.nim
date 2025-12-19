# nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

const
  # Some static noisy settings for `snap` debugging
  trSnapTraceGossipOk* = true
    ## `trace` log each sync network message.
  trEthTraceHandlerOk* = true
    ## `trace` application handler message.

# End
