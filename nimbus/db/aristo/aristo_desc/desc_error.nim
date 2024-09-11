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
    BlobifyNilVertex


    # Cache checker `checkCache()`
    CheckAnyVidDeadStorageRoot
    CheckAnyVidSharedStorageRoot
    CheckAnyVtxEmptyKeyMissing
    CheckAnyVtxEmptyKeyExpected
    CheckAnyVtxEmptyKeyMismatch
    CheckAnyVtxBranchLinksMissing
    CheckAnyVtxLockWithoutKey
    CheckAnyVTopUnset

    CheckBeCacheGarbledVTop
    CheckBeCacheKeyDangling
    CheckBeCacheKeyNonEmpty
    CheckBeGarbledVTop
    CheckBeVtxBranchLinksMissing
    CheckBeVtxInvalid
    CheckBeVtxMissing

    CheckStkKeyStrayZeroEntry
    CheckStkVtxKeyMismatch

    CheckRlxVtxIncomplete
    CheckRlxVtxKeyMissing
    CheckRlxVtxKeyMismatch


    # De-serialiser from `blobify.nim`
    Deblob256LenUnsupported
    Deblob64LenUnsupported
    DeblobBranchGotLeafPrefix
    DeblobBranchTooShort
    DeblobCodeLenUnsupported
    DeblobExtSizeGarbled
    DeblobLeafGotExtPrefix
    DeblobLeafSizeGarbled
    DeblobRVidLenUnsupported
    DeblobUnknown
    DeblobVtxTooShort
    DeblobWrongSize
    DeblobWrongType


    # Deletion of vertex paths, `deleteXxx()`
    DelAccRootNotAccepted
    DelBranchExpexted
    DelBranchWithoutRefs
    DelDanglingStoTrie
    DelLeafExpexted
    DelPathNotFound
    DelRootVidMissing
    DelStoAccMissing
    DelStoRootMissing
    DelStoRootNotAccepted
    DelVidStaleVtx

    # Functions from `aristo_desc.nim`
    DescMustBeOnCentre
    DescNotAllowedOnCentre
    DescStaleDescriptor


    # Functions from  `aristo_delta.nim`
    FilBackendMissing
    FilBackendRoMode
    FilSiblingsCommitUnfinshed


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
    HikeLeafUnexpected
    HikeNoLegs
    HikeRootMissing


    # Merge leaf `merge()`
    MergeHikeFailed # Ooops, internal error
    MergeAccRootNotAccepted
    MergeStoRootNotAccepted
    MergeLeafPathCachedAlready
    MergeLeafPathOnBackendAlready
    MergeRootVidMissing
    MergeStoAccMissing


    # Neighbour vertex, tree traversal `nearbyRight()` and `nearbyLeft()`
    NearbyBeyondRange
    NearbyBranchError
    NearbyDanglingLink
    NearbyEmptyHike
    NearbyFailed
    NearbyLeafExpected
    NearbyNestingTooDeep
    NearbyPathTailUnexpected
    NearbyUnexpectedVtx
    NearbyVidInvalid


    # Path/nibble/key conversions in `aisto_path.nim`
    PathExpected64Nibbles
    PathAtMost64Nibbles
    PathExpectedLeaf


    # Part/proof node errors
    PartArgNotGenericRoot
    PartArgNotInCore
    PartArgRootAlreadyOnDatabase
    PartArgRootAlreadyUsed
    PartChkChangedKeyNotInKeyTab
    PartChkChangedVtxMissing
    PartChkCoreKeyLookupFailed
    PartChkCoreRVidLookupFailed
    PartChkCoreVidLookupFailed
    PartChkCoreVtxMissing
    PartChkKeyTabCoreKeyMissing
    PartChkKeyTabRootMissing
    PartChkPerimeterVtxMustNotExist
    PartChkVidKeyTabKeyMismatch
    PartChkVidKeyTabLengthsDiffer
    PartChkVidTabCoreRootMissing
    PartChkVidTabVidMissing
    PartChnBranchPathExhausted
    PartChnBranchVoidEdge
    PartChnExtPfxMismatch
    PartChnLeafPathMismatch
    PartChnNodeConvError
    PartCtxNotAvailable
    PartCtxStaleDescriptor
    PartExtVtxExistsAlready
    PartExtVtxHasVanished
    PartExtVtxWasModified
    PartGarbledExtsInProofs
    PartMissingUplinkInternalError
    PartNoMoreRootVidsLeft
    PartPayloadAccRejected
    PartPayloadAccRequired
    PartRlp1r4ListEntries
    PartRlp2Or17ListEntries
    PartRlpBlobExpected
    PartRlpBranchHashKeyExpected
    PartRlpEmptyBlobExpected
    PartRlpExtHashKeyExpected
    PartRlpNodeException
    PartRlpNonEmptyBlobExpected
    PartRlpPayloadException
    PartRootKeysDontMatch
    PartRootVidsDontMatch
    PartTrkEmptyPath
    PartTrkFollowUpKeyMismatch
    PartTrkGarbledNode
    PartTrkLeafPfxMismatch
    PartTrkLinkExpected
    PartTrkPayloadMismatch
    PartTrkRlpError
    PartVtxSlotWasModified
    PartVtxSlotWasNotModified

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

# End
