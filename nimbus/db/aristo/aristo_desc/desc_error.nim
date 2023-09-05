# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

type
  AristoError* = enum
    NothingSerious = 0
    GenericError

    # Rlp decoder, `read()`
    Rlp2Or17ListEntries
    RlpBlobExpected
    RlpBranchLinkExpected
    RlpExtPathEncoding
    RlpNonEmptyBlobExpected
    RlpEmptyBlobExpected
    RlpRlpException
    RlpOtherException

    # Data record transcoders, `deblobify()` and `blobify()`
    BlobifyNilFilter
    BlobifyNilVertex
    BlobifyBranchMissingRefs
    BlobifyExtMissingRefs
    BlobifyExtPathOverflow
    BlobifyLeafPathOverflow
    BlobifyFilterRecordOverflow

    DeblobNilArgument
    DeblobUnknown
    DeblobTooShort
    DeblobBranchTooShort
    DeblobBranchSizeGarbled
    DeblobBranchInxOutOfRange
    DeblobExtTooShort
    DeblobExtSizeGarbled
    DeblobExtGotLeafPrefix
    DeblobLeafSizeGarbled
    DeblobLeafGotExtPrefix
    DeblobSizeGarbled
    DeblobWrongType
    DeblobPayloadTooShortInt64
    DeblobPayloadTooShortInt256
    DeblobNonceLenUnsupported
    DeblobBalanceLenUnsupported
    DeblobStorageLenUnsupported
    DeblobCodeLenUnsupported
    DeblobFilterTooShort
    DeblobFilterGenTooShort
    DeblobFilterTrpTooShort
    DeblobFilterTrpVtxSizeGarbled
    DeblobFilterSizeGarbled

    # Converter `asNode()`, currenly for unit tests only
    CacheMissingNodekeys

    # Path function `hikeUp()`
    HikeRootMissing
    HikeLeafTooEarly
    HikeBranchTailEmpty
    HikeBranchBlindEdge
    HikeExtTailEmpty
    HikeExtTailMismatch

    # Path/nibble/key conversions in `aisto_path.nim`
    PathExpected64Nibbles
    PathExpectedLeaf

    # Merge leaf `merge()`
    MergeBrLinkLeafGarbled
    MergeBrLinkVtxPfxTooShort
    MergeBranchGarbledNibble
    MergeBranchGarbledTail
    MergeBranchLinkLockedKey
    MergeBranchLinkProofModeLock
    MergeBranchProofModeLock
    MergeBranchRootExpected
    MergeLeafGarbledHike
    MergeLeafPathCachedAlready
    MergeNonBranchProofModeLock
    MergeRootBranchLinkBusy
    MergeAssemblyFailed # Ooops, internal error

    MergeHashKeyInvalid
    MergeRootVidInvalid
    MergeRootKeyInvalid
    MergeRevVidMustHaveBeenCached
    MergeHashKeyCachedAlready
    MergeHashKeyDiffersFromCached
    MergeNodeVtxDiffersFromExisting
    MergeRootKeyDiffersForVid

    # Update `Merkle` hashes `hashify()`
    HashifyCannotComplete
    HashifyCannotHashRoot
    HashifyExistingHashMismatch
    HashifyDownVtxlevelExceeded
    HashifyDownVtxLeafUnexpected
    HashifyRootHashMismatch
    HashifyRootVidMismatch
    HashifyVidCircularDependence
    HashifyVtxMissing

    # Cache checker `checkCache()`
    CheckStkVtxIncomplete
    CheckStkVtxKeyMissing
    CheckStkVtxKeyMismatch
    CheckStkRevKeyMissing
    CheckStkRevKeyMismatch
    CheckStkVtxCountMismatch

    CheckRlxVidVtxMismatch
    CheckRlxVtxIncomplete
    CheckRlxVtxKeyMissing
    CheckRlxVtxKeyMismatch
    CheckRlxRevKeyMissing
    CheckRlxRevKeyMismatch

    CheckAnyVidVtxMissing
    CheckAnyVtxEmptyKeyMissing
    CheckAnyVtxEmptyKeyExpected
    CheckAnyVtxEmptyKeyMismatch
    CheckAnyRevVtxMissing
    CheckAnyRevVtxDup
    CheckAnyRevCountMismatch
    CheckAnyVtxLockWithoutKey

    # Backend structural check `checkBE()`
    CheckBeVtxInvalid
    CheckBeKeyInvalid
    CheckBeVtxMissing
    CheckBeKeyMissing
    CheckBeKeyCantCompile
    CheckBeKeyMismatch
    CheckBeGarbledVGen

    CheckBeCacheIsDirty
    CheckBeCacheKeyMissing
    CheckBeCacheKeyNonEmpty
    CheckBeCacheVidUnsynced
    CheckBeCacheKeyDangling
    CheckBeCacheVtxDangling
    CheckBeCacheKeyCantCompile
    CheckBeCacheKeyMismatch
    CheckBeCacheGarbledVGen

    # Neighbour vertex, tree traversal `nearbyRight()` and `nearbyLeft()`
    NearbyBeyondRange
    NearbyBranchError
    NearbyDanglingLink
    NearbyEmptyHike
    NearbyExtensionError
    NearbyFailed
    NearbyBranchExpected
    NearbyLeafExpected
    NearbyNestingTooDeep
    NearbyPathTailUnexpected
    NearbyPathTailInxOverflow
    NearbyUnexpectedVtx
    NearbyVidInvalid

    # Deletion of vertices, `delete()`
    DelPathTagError
    DelLeafExpexted
    DelLeafLocked
    DelLeafUnexpected
    DelBranchExpexted
    DelBranchLocked
    DelBranchWithoutRefs
    DelExtLocked
    DelVidStaleVtx

    # Functions from  `aristo_filter.nim`
    FilBackendMissing
    FilBackendRoMode
    FilDudeFilterUpdateError
    FilExecDublicateSave
    FilExecHoldExpected
    FilExecOops
    FilExecSaveMissing
    FilExecStackUnderflow
    FilInxByFidFailed
    FilNilFilterRejected
    FilNotReadOnlyDude
    FilPosArgExpected
    FilPrettyPointlessLayer
    FilQidByLeFidFailed
    FilQuSchedDisabled
    FilStateRootMismatch
    FilStateRootMissing
    FilTrgSrcMismatch
    FilTrgTopSrcMismatch

    # Get functions form `aristo_get.nim`
    GetLeafNotFound
    GetVtxNotFound
    GetKeyNotFound
    GetFilNotFound
    GetIdgNotFound
    GetFqsNotFound

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
    TxRoBackendOrMissing
    TxNoPendingTx
    TxPendingTx
    TxNotTopTx
    TxStackGarbled
    TxStackUnderflow

    # Miscelaneous handy helpers
    PayloadTypeUnsupported
    AccountRlpDecodingError
    AccountStorageKeyMissing
    AccountVtxUnsupported
    AccountNodeUnsupported

# End
