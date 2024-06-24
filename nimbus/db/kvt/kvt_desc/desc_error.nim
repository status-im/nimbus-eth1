# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
    RdbBeDelayedAlreadyRegistered
    RdbBeDelayedLocked
    RdbBeDelayedNotReady
    RdbBeDriverDelError
    RdbBeDriverGetError
    RdbBeDriverInitError
    RdbBeDriverPutError
    RdbBeDriverWriteError
    RdbBeHostError
    RdbBeHostNotApplicable

    # Transaction wrappers
    TxArgStaleTx
    TxBackendNotWritable
    TxLevelTooDeep
    TxLevelUseless
    TxNoPendingTx
    TxNotTopTx
    TxPendingTx
    TxPersistDelayed
    TxStackGarbled
    TxStackUnderflow

    # Filter management
    FilBackendMissing
    FilBackendRoMode
    FilSiblingsCommitUnfinshed

    # Functions from `kvt_desc`
    MustBeOnCentre
    NotAllowedOnCentre
    StaleDescriptor

# End
