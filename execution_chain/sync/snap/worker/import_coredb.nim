# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Not for production, yet.
## ------------------------
##
## Module depends on CoreDb/Aristo. This module serves as a template for
## how to flush and re-fill production Aristo from the flat snap sync
## tables once they are ready.
##
{.push raises: [].}

import
  ./import_coredb/[coredb_desc, coredb_import, coredb_stats]

export
  coredb_desc,
  coredb_import,
  coredb_stats

# End
