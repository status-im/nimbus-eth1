# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

type
  KvtError* = enum
    NothingSerious = 0
    GenericError

    GetNotFound
    KeyInvalid
    DataInvalid

    # RocksDB backend
    RdbBeCantCreateDataDir
    RdbBeCantCreateBackupDir
    RdbBeCantCreateTmpDir
    RdbBeDriverInitError
    RdbBeDriverGetError
    RdbBeDriverDelError
    RdbBeCreateSstWriter
    RdbBeOpenSstWriter
    RdbBeAddSstWriter
    RdbBeFinishSstWriter
    RdbBeIngestSstWriter

    # Transaction wrappers
    TxArgStaleTx
    TxBackendNotWritable
    TxNoPendingTx
    TxPendingTx
    TxNotTopTx
    TxStackGarbled
    TxStackUnderflow

    # Functions from `kvt_desc`
    MustBeOnCentre
    NotAllowedOnCentre

# End
