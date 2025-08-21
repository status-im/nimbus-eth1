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

    CheckBeCacheGarbledVTop
    CheckBeCacheKeyDangling
    CheckBeCacheKeyNonEmpty
    CheckBeGarbledVTop
    CheckBeVtxBranchLinksMissing
    CheckBeVtxInvalid
    CheckBeVtxMissing

    CheckStkKeyStrayZeroEntry
    CheckStkVtxKeyMismatch

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
    DelBranchExpexted
    DelBranchWithoutRefs
    DelLeafExpexted
    DelVidStaleVtx

    # Fetch functions from `aristo_fetch.nim`
    FetchAccInaccessible
    FetchAccPathWithoutLeaf
    FetchPathNotFound
    FetchPathStoRootMissing

    # Get functions from `aristo_get.nim`
    GetKeyNotFound
    GetKeyUpdateNeeded
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
    MergeNoAction
    MergeStoAccMissing

    # Part/proof node errors
    PartChnBranchPathExhausted
    PartChnBranchVoidEdge
    PartChnExtPfxMismatch
    PartChnLeafPathMismatch
    PartChnNodeConvError
    PartTrkEmptyPath
    PartTrkEmptyProof
    PartTrkFollowUpKeyMismatch
    PartTrkGarbledNode
    PartTrkLeafPfxMismatch
    PartTrkLinkExpected
    PartTrkRlpError

    # RocksDB backend
    RdbBeCantCreateTmpDir
    RdbBeDriverDelAdmError
    RdbBeDriverDelVtxError
    RdbBeDriverGetAdmError
    RdbBeDriverGetKeyError
    RdbBeDriverGetVtxError
    RdbBeDriverPutAdmError
    RdbBeDriverPutVtxError
    RdbBeDriverWriteError


# End
