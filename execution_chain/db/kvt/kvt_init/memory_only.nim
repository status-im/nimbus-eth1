# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Non persistent constructors for Kvt DB
## ======================================
##
{.push raises: [].}

import
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  "."/[init_common, memory_db]

export
  BackendType,
  MemBackendRef

# ------------------------------------------------------------------------------
# Public helpers
# -----------------------------------------------------------------------------

func kind*(
    be: BackendRef;
      ): BackendType =
  ## Retrieves the backend type symbol for a `be` backend database argument
  ## where `BackendVoid` is returned for the`nil` backend.
  doAssert(not be.isNil)
  be.TypedBackendRef.beKind

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type KvtDbRef;                         # Target type
    B: type MemBackendRef;                   # Backend type
      ): T =
  ## Memory backend constructor.
  ##
  let db = KvtDbRef(txRef: KvtTxRef(), backend: memoryBackend())
  db.txRef.db = db
  db

proc finish*(db: KvtDbRef; eradicate = false) =
  ## Backend destructor. The argument `eradicate` indicates that a full
  ## database deletion is requested. If set `false` the outcome might differ
  ## depending on the type of backend (e.g. the `BackendMemory` backend will
  ## always eradicate on close.)
  ##
  if not db.backend.isNil:
    db.backend.closeFn eradicate

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
