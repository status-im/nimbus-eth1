# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
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
  ./kvt/kvt_init/[rocks_db, init_common]

proc synchronizerKvt*(be: TypedBackendRef): KvtTxRef =
  ## Create a special txFrame for storing temporary
  ## block headers from syncer with it's own column family.
  ## This txFrame is completely isolated from ordinary headers.
  doAssert be.beKind == BackendRocksDB
  let
    baseDb = RdbBackendRef(be).getBaseDb()
    rdb = rocksDbKvtBackend(baseDb, KvtType.Synchro)
  rdb.txRef = KvtTxRef(db: rdb)
  rdb.txRef
