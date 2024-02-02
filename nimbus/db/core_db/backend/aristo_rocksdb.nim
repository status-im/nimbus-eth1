# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  ../../aristo,
  ../../aristo/[aristo_persistent, aristo_walk/persistent],
  ../../kvt,
  ../../kvt/kvt_persistent,
  ../base,
  ./aristo_db,
  ./aristo_db/handlers_aristo

include
  ./aristo_db/aristo_replicate

# Annotation helper(s)
{.pragma: rlpRaise, gcsafe, raises: [AristoApiRlpError].}

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
# Public aristo iterators
# ------------------------------------------------------------------------------

iterator aristoReplicateRdb*(dsc: CoreDxMptRef): (Blob,Blob) {.rlpRaise.} =
  ## Instantiation for `VoidBackendRef`
  for k,v in aristoReplicate[aristo_persistent.RdbBackendRef](dsc):
    yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
