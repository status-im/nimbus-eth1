# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  web3/execution_types,
  ../beacon_engine

{.push gcsafe, raises:[].}

proc getInclusionList*(ben: BeaconEngineRef,
                       apiVersion: Version): InclusionList =
  discard
