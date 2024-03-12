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
    HikeBranchMissingEdge
    HikeBranchTailEmpty
    HikeEmptyPath
    HikeExtTailEmpty
    HikeExtTailMismatch
    HikeLeafUnexpected
    HikeNoLegs
    HikeRootMissing

    # Path/nibble/key conversions in `aisto_path.nim`
    PathExpected64Nibbles
    PathAtMost64Nibbles
    PathExpectedLeaf

    # Merge leaf `merge()`
    MergeBranchLinkLeafGarbled
    MergeBranchLinkVtxPfxTooShort
    MergeBranchGarbledNibble
    MergeBranchGarbledTail
    MergeBranchLinkLockedKey
    MergeBranchLinkProofModeLock
    MergeBranchProofModeLock
    MergeBranchRootExpected
    MergeLeafGarbledHike
    MergeLeafPathCachedAlready
    MergeLeafPathOnBackendAlready
    MergeNonBranchProofModeLock
    MergeRootBranchLinkBusy
    MergeRootMissing
    MergeAssemblyFailed # Ooops, internal error

    MergeHashKeyInvalid
    MergeHashKeyDiffersFromCached
    MergeHashKeyRevLookUpGarbled
    MergeRootVidInvalid
    MergeRootKeyInvalid
    MergeProofInitMissing
    MergeRevVidMustHaveBeenCached
    MergeNodeVtxDiffersFromExisting
    MergeRootKeyDiffersForVid
    MergeNodeVtxDuplicates
    MergeRootKeyMissing
    MergeRootArgsIncomplete

    # Utils
    UtilsAccPathMissing
    UtilsAccPathWithoutLeaf
    UtilsAccUnaccessible
    UtilsAccWrongStorageRoot
    UtilsStoRootMissing

    # Update `Merkle` hashes `hashify()`
    HashifyVtxUnresolved
    HashifyRootVtxUnresolved
    HashifyProofHashMismatch

    # Cache checker `checkCache()`
    CheckStkKeyStrayZeroEntry
    CheckStkVtxIncomplete
    CheckStkVtxKeyMismatch
    CheckStkVtxKeyMissing

    CheckRlxVidVtxMismatch
    CheckRlxVtxIncomplete
    CheckRlxVtxKeyMissing
    CheckRlxVtxKeyMismatch

    CheckAnyVtxEmptyKeyMissing
    CheckAnyVtxEmptyKeyExpected
    CheckAnyVtxEmptyKeyMismatch
    CheckAnyVtxBranchLinksMissing
    CheckAnyVtxExtPfxMissing
    CheckAnyVtxLockWithoutKey

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
    DelBranchExpexted
    DelBranchLocked
    DelBranchWithoutRefs
    DelDanglingStoTrie
    DelExtLocked
    DelLeafExpexted
    DelLeafLocked
    DelLeafUnexpected
    DelPathNotFound
    DelPathTagError
    DelSubTreeTooBig
    DelSubTreeVoidRoot
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
    FilSrcTrgInconsistent

    # Get functions from `aristo_get.nim`
    GetLeafMissing
    GetKeyUpdateNeeded

    GetLeafNotFound
    GetVtxNotFound
    GetKeyNotFound
    GetFilNotFound
    GetIdgNotFound
    GetFqsNotFound

    # Fetch functions from `aristo_fetch.nim`
    FetchPathNotFound
    LeafKeyInvalid

    # RocksDB backend
    RdbBeCantCreateDataDir
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
    TxGarbledSpan

    # Functions from `aristo_desc.nim`
    MustBeOnCentre
    NotAllowedOnCentre
    StaleDescriptor

    # Functions from `aristo_utils.nim`
    AccRlpDecodingError
    AccStorageKeyMissing
    AccVtxUnsupported
    AccNodeUnsupported
    PayloadTypeUnsupported

    # Miscelaneous handy helpers
    AccRootUnacceptable
    MptRootUnacceptable
    MptRootMissing
    NotImplemented
    TrieInvalid
    VidContextLocked

# End
