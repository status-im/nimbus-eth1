# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
## This module provides the API only - actual implementations are available from:
##
## * `db/code_db/memory_only` - in-memory database (avoids linking to db library)
## * `db/code_db/persistent` - on-disk database that is persistent between runs
##
{.push raises: [].}

import ./core_db/[base_desc, base, core_apps]
export base_desc, base, core_apps

# Default database backend selection.
const DefaultDbMemory* = AristoDbMemory
const DefaultDbPersistent* = AristoDbRocks

# End
