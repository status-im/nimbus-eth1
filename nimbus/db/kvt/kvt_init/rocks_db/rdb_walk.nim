# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB store data iterator
## ============================
##
{.push raises: [].}

import
  eth/common,
  rocksdb,
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import
    chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator walk*(rdb: RdbInst): tuple[key: Blob, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over and ignored.
  block walkBody:
    let rit = rdb.store[KvtGeneric].openIterator().valueOr:
      when extraTraceMessages:
        trace logTxt "walk", pfx="all", error
      break walkBody
    defer: rit.close()

    for (key,val) in rit.pairs:
      if 0 < key.len:
        yield (key, val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
