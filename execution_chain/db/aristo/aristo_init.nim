# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Constructors for Aristo DB
## ==========================
##
## See `./README.md` for implementation details
##
## This module provides a memory database only. For providing a persistent
## constructor, import `aristo_init/persistent` though avoiding to
## unnecessarily link to the persistent backend library (e.g. `rocksdb`)
## when a memory only database is used.
##
{.push raises: [].}

import
  ./aristo_init/memory_only
export
  memory_only

# End
