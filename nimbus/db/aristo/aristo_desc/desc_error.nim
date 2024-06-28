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

    # Miscelaneous/unclassified handy helpers
    GenericError


    # Data record transcoders, `blobify()` from `blobify.nim`
    BlobifyBranchMissingRefs
    BlobifyExtMissingRefs
    BlobifyExtPathOverflow
    BlobifyLeafPathOverflow
    BlobifyNilFilter
    BlobifyNilVertex


    # Cache checker `checkCache()`
    CheckAnyVidDeadStorageRoot
    CheckAnyVidSharedStorageRoot
    CheckAnyVtxEmptyKeyMissing
    CheckAnyVtxEmptyKeyExpected
    CheckAnyVtxEmptyKeyMismatch
    CheckAnyVtxBranchLinksMissing
    CheckAnyVtxExtPfxMissing
    CheckAnyVtxLockWithoutKey
    CheckAnyVTopUnset

    CheckBeCacheGarbledVTop
    CheckBeCacheIsDirty
    CheckBeCacheKeyCantCompile
    CheckBeCacheKeyDangling
    CheckBeCacheKeyMismatch
    CheckBeCacheKeyMissing
    CheckBeCacheKeyNonEmpty
    CheckBeCacheVidUnsynced
    CheckBeCacheVtxDangling
    CheckBeFifoSrcTrgMismatch
    CheckBeFifoTrgNotStateRoot
    CheckBeGarbledVTop
    CheckBeKeyCantCompile
    CheckBeKeyInvalid
    CheckBeKeyMismatch
    CheckBeKeyMissing
    CheckBeVtxBranchLinksMissing
    CheckBeVtxExtPfxMissing
    CheckBeVtxInvalid
    CheckBeVtxMissing

    CheckStkKeyStrayZeroEntry
    CheckStkVtxIncomplete
    CheckStkVtxKeyMismatch
    CheckStkVtxKeyMissing

    CheckRlxVidVtxMismatch
    CheckRlxVtxIncomplete
    CheckRlxVtxKeyMissing
    CheckRlxVtxKeyMismatch


    # De-serialiser from `blobify.nim`
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
    DeblobWrongSize
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


    # Deletion of vertex paths, `deleteXxx()`
    DelAccRootNotAccepted
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
    DelRootVidMissing
    DelStoAccMissing
    DelStoRootMissing
    DelStoRootNotAccepted
    DelSubTreeAccRoot
    DelSubTreeVoidRoot
    DelVidStaleVtx


    # Functions from `aristo_desc.nim`
    DescMustBeOnCentre
    DescNotAllowedOnCentre
    DescStaleDescriptor


    # Functions from  `aristo_filter.nim`
    FilBackendMissing
    FilBackendRoMode
    FilNilFilterRejected
    FilSiblingsCommitUnfinshed
    FilSrcTrgInconsistent
    FilStateRootMismatch
    FilTrgSrcMismatch


    # Fetch functions from `aristo_fetch.nim`
    FetchAccInaccessible
    FetchAccPathWithoutLeaf
    FetchAccRootNotAccepted
    FetchLeafKeyInvalid
    FetchPathInvalid
    FetchPathNotFound
    FetchRootVidMissing
    FetchStoRootNotAccepted


    # Get functions from `aristo_get.nim`
    GetFilNotFound
    GetFqsNotFound
    GetKeyNotFound
    GetKeyUpdateNeeded
    GetLstNotFound
    GetTuvNotFound
    GetVtxNotFound


    # Path function `hikeUp()`
    HikeBranchMissingEdge
    HikeBranchTailEmpty
    HikeDanglingEdge
    HikeEmptyPath
    HikeExtMissingEdge
    HikeExtTailEmpty
    HikeExtTailMismatch
    HikeLeafUnexpected
    HikeNoLegs
    HikeRootMissing


    # Merge leaf `merge()`
    MergeAssemblyFailed # Ooops, internal error
    MergeAccRootNotAccepted
    MergeStoRootNotAccepted
    MergeBranchGarbledNibble
    MergeBranchGarbledTail
    MergeBranchLinkLeafGarbled
    MergeBranchLinkVtxPfxTooShort
    MergeBranchProofModeLock
    MergeBranchRootExpected
    MergeHashKeyDiffersFromCached
    MergeHashKeyInvalid
    MergeLeafGarbledHike
    MergeLeafPathCachedAlready
    MergeLeafPathOnBackendAlready
    MergeLeafProofModeLock
    MergeLeafTypeAccountRequired
    MergeLeafTypeRawDataRequired
    MergeNodeAccountPayloadError
    MergeNodeVidMissing
    MergeNodeVtxDiffersFromExisting
    MergeNonBranchProofModeLock
    MergeProofInitMissing
    MergeRevVidMustHaveBeenCached
    MergeRootArgsIncomplete
    MergeRootBranchLinkBusy
    MergeRootKeyDiffersForVid
    MergeRootKeyInvalid
    MergeRootKeyMissing
    MergeRootKeyNotInProof
    MergeRootKeysMissing
    MergeRootKeysOverflow
    MergeRootVidMissing
    MergeStoAccMissing


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


    # Path/nibble/key conversions in `aisto_path.nim`
    PathExpected64Nibbles
    PathAtMost64Nibbles
    PathExpectedLeaf


    # RocksDB backend
    RdbBeCantCreateDataDir
    RdbBeCantCreateTmpDir
    RdbBeDriverDelAdmError
    RdbBeDriverDelKeyError
    RdbBeDriverDelVtxError
    RdbBeDriverGetAdmError
    RdbBeDriverGetKeyError
    RdbBeDriverGetVtxError
    RdbBeDriverGuestError
    RdbBeDriverPutAdmError
    RdbBeDriverPutKeyError
    RdbBeDriverPutVtxError
    RdbBeDriverWriteError
    RdbBeTypeUnsupported
    RdbBeWrSessionUnfinished
    RdbBeWrTriggerActiveAlready
    RdbBeWrTriggerNilFn
    RdbGuestInstanceAborted
    RdbGuestInstanceUnsupported
    RdbHashKeyExpected


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


    # Transaction wrappers
    TxAccRootMissing
    TxArgStaleTx
    TxArgsUseless
    TxBackendNotWritable
    TxLevelTooDeep
    TxLevelUseless
    TxNoPendingTx
    TxNotFound
    TxNotTopTx
    TxPendingTx
    TxPrettyPointlessLayer
    TxStackGarbled
    TxStackUnderflow
    TxStateRootMismatch


    # Functions from `aristo_utils.nim`
    UtilsAccLeafPayloadExpected
    UtilsAccNodeUnsupported
    UtilsAccPathMissing
    UtilsAccStorageKeyMissing
    UtilsAccVtxUnsupported
    UtilsAccWrongStorageRoot
    UtilsPayloadTypeUnsupported
    UtilsStoRootMissing

# End
