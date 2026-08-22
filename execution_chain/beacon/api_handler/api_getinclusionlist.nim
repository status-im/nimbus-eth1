# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  json_rpc/errors,
  web3/execution_types,
  ../../core/tx_pool,
  ../beacon_engine,
  ./api_utils

{.push gcsafe, raises:[].}

proc getInclusionList*(ben: BeaconEngineRef,
                       apiVersion: Version): InclusionList  {.raises: [ApplicationError].} =

  if apiVersion == Version.V1:
    return ben.txPool.getInclusionListV1()
  else:
    raise invalidParams("[getInclusionList] unsupported apiVersion: " & $apiVersion)
