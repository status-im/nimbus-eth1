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
    BlobifyBranchMissingRefs
    BlobifyExtMissingRefs
    BlobifyExtPathOverflow
    BlobifyLeafPathOverflow
    BlobifyNilFilter
    BlobifyNilVertex
    BlobifyStateSrcLenGarbled
    BlobifyStateTrgLenGarbled

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

    # Converter `asNode()`, currenly for unit tests only
    CacheMissingNodekeys

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

    # Path/nibble/key conversions in `aisto_path.nim`
    PathExpected64Nibbles
    PathAtMost64Nibbles
    PathExpectedLeaf

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
    MergeLeafCantChangeStorageID
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

    CheckAnyVidDeadStorageRoot
    CheckAnyVidSharedStorageRoot
    CheckAnyVtxEmptyKeyMissing
    CheckAnyVtxEmptyKeyExpected
    CheckAnyVtxEmptyKeyMismatch
    CheckAnyVtxBranchLinksMissing
    CheckAnyVtxExtPfxMissing
    CheckAnyVtxLockWithoutKey
    CheckAnyVTopUnset

    # Backend structural check `checkBE()`
    CheckBeVtxInvalid
    CheckBeVtxMissing
    CheckBeVtxBranchLinksMissing
    CheckBeVtxExtPfxMissing
    CheckBeKeyInvalid
    CheckBeKeyMissing
    CheckBeKeyCantCompile
    CheckBeKeyMismatch
    CheckBeGarbledVTop

    CheckBeCacheIsDirty
    CheckBeCacheKeyMissing
    CheckBeCacheKeyNonEmpty
    CheckBeCacheVidUnsynced
    CheckBeCacheKeyDangling
    CheckBeCacheVtxDangling
    CheckBeCacheKeyCantCompile
    CheckBeCacheKeyMismatch
    CheckBeCacheGarbledVTop

    CheckBeFifoSrcTrgMismatch
    CheckBeFifoTrgNotStateRoot

    # Jornal check `checkJournal()`
    CheckJrnCachedQidOverlap
    CheckJrnSavedQidMissing
    CheckJrnSavedQidStale
    CheckJrnLinkingGap

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

    # Functions from  `aristo_filter.nim`
    FilBackendMissing
    FilBackendRoMode
    FilNilFilterRejected
    FilSiblingsCommitUnfinshed
    FilSrcTrgInconsistent
    FilStateRootMismatch
    FilTrgSrcMismatch

    # Get functions from `aristo_get.nim`
    GetLeafMissing
    GetKeyUpdateNeeded

    GetLeafNotFound
    GetVtxNotFound
    GetKeyNotFound
    GetFilNotFound
    GetTuvNotFound
    GetLstNotFound
    GetFqsNotFound

    # Fetch functions from `aristo_fetch.nim`
    FetchPathNotFound
    LeafKeyInvalid

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
    TxStackGarbled
    TxStackUnderflow

    TxPrettyPointlessLayer
    TxStateRootMismatch

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

    UtilsAccPathMissing
    UtilsAccPathWithoutLeaf
    UtilsAccInaccessible
    UtilsAccWrongStorageRoot
    UtilsStoRootInaccessible
    UtilsStoRootMissing
    UtilsAccLeafPayloadExpected

    # Miscelaneous handy helpers
    AccRootUnacceptable
    MptRootUnacceptable
    MptRootMissing
    NotImplemented
    TrieInvalid
    VidContextLocked

# End
