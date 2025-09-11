# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ../kvt_desc/desc_error

const
  verifyIxId = true # and false
    ## Enforce session tracking

type
  BackendType* = enum
    BackendMemory                    ## Same as Aristo
    BackendRocksDB                   ## Same as Aristo

  TypedBackendRef* = ref object of RootObj
    beKind*: BackendType             ## Backend type identifier

  PutHdlRef* = ref object of RootRef
    ## Persistent database transaction frame handle. This handle is used to
    ## wrap any of `PutVtxFn`, `PutKeyFn`, and `PutIdgFn` into and atomic
    ## transaction frame. These transaction frames must not be interleaved
    ## by any library function using the backend.

  TypedPutHdlRef* = ref object of PutHdlRef
    error*: KvtError                 ## Track error while collecting transaction
    info*: string                    ##  Error description (if any)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
