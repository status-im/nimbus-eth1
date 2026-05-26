# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../aristo,
  ./backend/aristo_memory,
  ./[base, core_apps]

export
  EmptyBlob,
  base,
  core_apps

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc newCoreDbRef*(
    dbType: static[CoreDbType];      # Database type symbol
      ): CoreDbRef =
  ## Constructor for volatile/memory type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  ##
  when dbType == AristoDbMemory:
    newMemoryCoreDbRef()

  else:
    {.error: "Unsupported constructor " & $dbType & ".newCoreDbRef()".}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
