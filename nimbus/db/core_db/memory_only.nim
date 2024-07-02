# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common,
  ../aristo,
  ./backend/aristo_db,
  "."/[base_iterators, core_apps]

import
  ./base except bless

export
  EmptyBlob,
  base,
  base_iterators,
  common,
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
    newAristoMemoryCoreDbRef()

  elif dbType == AristoDbVoid:
    newAristoVoidCoreDbRef()

  else:
    {.error: "Unsupported constructor " & $dbType & ".newCoreDbRef()".}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
