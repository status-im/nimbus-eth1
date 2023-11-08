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
    RlpBranchHashKeyExpected
    RlpEmptyBlobExpected
    RlpExtHashKeyExpected
    RlpHashKeyExpected
    RlpNonEmptyBlobExpected
    RlpOtherException
    RlpRlpException

    # Serialise decoder
    SerCantResolveStorageRoot

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
    DeblobVtxTooShort
    DeblobHashKeyExpected
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
    HikeEmptyPath
    HikeLeafTooEarly
    HikeBranchTailEmpty
    HikeBranchBlindEdge
    HikeExtTailEmpty
    HikeExtTailMismatch

    # Path/nibble/key conversions in `aisto_path.nim`
    PathExpected64Nibbles
    PathAtMost64Nibbles
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
    MergeHashKeyCachedAlready
    MergeHashKeyDiffersFromCached
    MergeHashKeyRevLookUpGarbled
    MergeRootVidInvalid
    MergeRootKeyInvalid
    MergeRevVidMustHaveBeenCached
    MergeNodeVtxDiffersFromExisting
    MergeRootKeyDiffersForVid
    MergeNodeVtxDuplicates

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
    CheckAnyVtxBranchLinksMissing
    CheckAnyVtxExtPfxMissing
    CheckAnyVtxLockWithoutKey
    CheckAnyRevVtxMissing
    CheckAnyRevVtxDup
    CheckAnyRevCountMismatch

    # Backend structural check `checkBE()`
    CheckBeVtxInvalid
    CheckBeVtxMissing
    CheckBeVtxBranchLinksMissing
    CheckBeVtxExtPfxMissing
    CheckBeKeyInvalid
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

    CheckBeFifoSrcTrgMismatch
    CheckBeFifoTrgNotStateRoot

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
    FilBackStepsExpected
    FilDudeFilterUpdateError
    FilExecDublicateSave
    FilExecHoldExpected
    FilExecOops
    FilExecSaveMissing
    FilExecStackUnderflow
    FilFilterInvalid
    FilFilterNotFound
    FilInxByQidFailed
    FilNegativeEpisode
    FilNilFilterRejected
    FilNoMatchOnFifo
    FilPrettyPointlessLayer
    FilQidByLeFidFailed
    FilQuSchedDisabled
    FilStateRootMismatch
    FilStateRootMissing
    FilTrgSrcMismatch
    FilTrgTopSrcMismatch
    FilSiblingsCommitUnfinshed

    # Get functions from `aristo_get.nim`
    GetLeafNotFound
    GetVtxNotFound
    GetKeyNotFound
    GetKeyTempLocked
    GetFilNotFound
    GetIdgNotFound
    GetFqsNotFound

    # Fetch functions from `aristo_fetch.nim`
    FetchPathNotFound

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
    RdbHashKeyExpected

    # Transaction wrappers
    TxArgStaleTx
    TxBackendNotWritable
    TxNoPendingTx
    TxPendingTx
    TxNotTopTx
    TxStackGarbled
    TxStackUnderflow
    TxSpanOffCentre
    TxGarbledSpan

    # Functions from `aristo_desc`
    CentreTxLocked
    MustBeOnCentre
    NotAllowedOnCentre
    GarbledTxSpan
    OutsideTxSpan

    # Miscelaneous handy helpers
    PayloadTypeUnsupported
    LeafKeyInvalid
    AccountRlpDecodingError
    AccountStorageKeyMissing
    AccountVtxUnsupported
    AccountNodeUnsupported
    NotImplemented

# End
