# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ../../aristo/aristo_init/init_common,
  ../kvt_desc,
  ../kvt_desc/desc_backend

export
  BackendType # borrowed from Aristo

const
  verifyIxId = true # and false
    ## Enforce session tracking

type
  TypedBackendRef* = ref object of BackendRef
    beKind*: BackendType             ## Backend type identifier
    when verifyIxId:
      txGen: uint                    ## Transaction ID generator (for debugging)
      txId: uint                     ## Active transaction ID (for debugging)

  TypedPutHdlRef* = ref object of PutHdlRef
    error*: KvtError                 ## Track error while collecting transaction
    when verifyIxId:
      txId: uint                     ## Transaction ID (for debugging)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc beginSession*(hdl: TypedPutHdlRef; db: TypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == 0
    if db.txGen == 0:
      db.txGen = 1
    db.txId = db.txGen
    hdl.txId = db.txGen
    db.txGen.inc

proc verifySession*(hdl: TypedPutHdlRef; db: TypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == hdl.txId

proc finishSession*(hdl: TypedPutHdlRef; db: TypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == hdl.txId
    db.txId = 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
