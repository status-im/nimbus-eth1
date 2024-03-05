# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.


{.used.}

import
  std/os,
  unittest2,
  eth/db/kvstore,
  ../../nimbus/db/kvstore_rocksdb,
  eth/../tests/db/test_kvstore

suite "RocksStoreRef":
  test "KvStore interface":
    let tmp = getTempDir() / "nimbus-test-db"
    removeDir(tmp)

    let db = RocksStoreRef.init(tmp, "test")[]
    defer:
      db.close()

    testKvStore(kvStore db, false, false)
