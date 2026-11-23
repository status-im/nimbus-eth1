# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  ./kvt/kvt_desc,
  ./kvt/kvt_init/[memory_db, rocks_db, init_common]

proc synchronizerKvt*(be: TypedBackendRef): KvtDbRef =
  ## Create a special txFrame for storing temporary
  ## block headers from syncer with it's own column family.
  ## This txFrame is completely isolated from ordinary headers.
  ## With a memory backend (e.g. in tests), a separate memory store is used.
  if be of RdbBackendRef:
    rocksDbKvtBackend(RdbBackendRef(be).getBaseDb(), KvtSynchro)
  else:
    memoryBackend()
