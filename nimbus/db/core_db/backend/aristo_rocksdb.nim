# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common,
  results,
  "../.."/[aristo, aristo/aristo_persistent, kvt, kvt/kvt_persistent],
  ../base,
  ./aristo_db

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newAristoRocksDbCoreDbRef*(path: string; qlr: QidLayoutRef): CoreDbRef =
  AristoDbRocks.init(
    kvt_persistent.RdbBackendRef,
    aristo_persistent.RdbBackendRef,
    path, qlr)

proc newAristoRocksDbCoreDbRef*(path: string): CoreDbRef =
  AristoDbRocks.init(
    kvt_persistent.RdbBackendRef,
    aristo_persistent.RdbBackendRef,
    path)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
