# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
    DelRootVidMissing
    DelStoRootNotAccepted
    DelVidStaleVtx

    # Fetch functions from `aristo_fetch.nim`
    FetchAccInaccessible
    FetchAccPathWithoutLeaf
    FetchAccRootNotAccepted
    FetchLeafKeyInvalid
    FetchPathInvalid
    FetchPathNotFound
    FetchPathStoRootMissing
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
    MergeNoAction
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
    PartChnBranchPathExhausted
    PartChnBranchVoidEdge
    PartChnExtPfxMismatch
    PartChnLeafPathMismatch
    PartChnNodeConvError
    PartTrkEmptyPath
    PartTrkFollowUpKeyMismatch
    PartTrkGarbledNode
    PartTrkLeafPfxMismatch
    PartTrkLinkExpected
    PartTrkRlpError

    # RocksDB backend
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


# End
