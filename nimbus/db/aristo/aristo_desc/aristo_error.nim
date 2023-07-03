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
    BlobifyBranchMissingRefs
    BlobifyExtMissingRefs
    BlobifyExtPathOverflow
    BlobifyLeafPathOverflow

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
    HashifyLeafToRootAllFailed
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

    # Save permanently, `save()`
    SaveBackendMissing
    SaveLeafVidRepurposed

    # Get functions form `aristo_get.nim`
    GetLeafNotFound

    # All backend and get functions form `aristo_get.nim`
    GetVtxNotFound
    GetKeyNotFound

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

# End
