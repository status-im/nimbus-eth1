# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../../aristo as use_ari,
  ../../aristo/[aristo_init/memory_only, aristo_walk/memory_only],
  ../../kvt as use_kvt,
  ../../kvt/[kvt_init/memory_only, kvt_walk/memory_only],
  ../base_desc

export base_desc

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc newMemoryCoreDbRef*(): CoreDbRef =
  CoreDbRef(mpt: AristoDbRef.init(), kvt: KvtDbRef.init())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
