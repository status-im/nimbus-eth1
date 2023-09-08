# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  ../db/select_backend,
  ./handlers/eth as handlers_eth,
  ./handlers/setup as handlers_setup

export
  handlers_eth, handlers_setup

when dbBackend != select_backend.none:
  import
    ./handlers/snap as handlers_snap

  export
    handlers_snap

static:
  type
    StopMoaningAboutUnusedEth = EthWireRef

# End
