# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common,
  ../../nimbus/db/era1_db

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpBlocksEra1*(dir: string): (seq[BlockHeader],seq[BlockBody]) =
  let db = Era1DbRef.init dir
  defer: db.dispose()

  doAssert db.hasAllKeys(0,500) # check whether `init()` succeeded

  for w in db.headerBodyPairs:
    yield w

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
