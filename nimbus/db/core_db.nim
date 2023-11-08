# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Core database replacement wrapper object
## ========================================
##
## See `core_db/README.md` for implementation details
##
## This module provides a memory datanase only. For providing a persistent
## constructor, import `db/code_db/persistent` though avoiding to
## unnecessarily link to the persistent backend library (e.g. `rocksdb`)
## when a memory only database is used.
##
{.push raises: [].}

import
  ./core_db/memory_only
export
  memory_only

# End
