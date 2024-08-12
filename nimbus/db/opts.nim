# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import results

export results

const
  # https://github.com/facebook/rocksdb/wiki/Setup-Options-and-Basic-Tuning
  defaultMaxOpenFiles* = 512
  defaultWriteBufferSize* = 64 * 1024 * 1024
  defaultRowCacheSize* = 1024 * 1024 * 1024
  defaultBlockCacheSize* = 2 * 1024 * 1024 * 1024

type DbOptions* = object # Options that are transported to the database layer
  maxOpenFiles*: int
  writeBufferSize*: int
  rowCacheSize*: int
  blockCacheSize*: int

func init*(
    T: type DbOptions,
    maxOpenFiles = defaultMaxOpenFiles,
    writeBufferSize = defaultWriteBufferSize,
    rowCacheSize = defaultRowCacheSize,
    blockCacheSize = defaultBlockCacheSize,
): T =
  T(
    maxOpenFiles: maxOpenFiles,
    writeBufferSize: writeBufferSize,
    rowCacheSize: rowCacheSize,
    blockCacheSize: blockCacheSize,
  )
