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

    # Rlp decoder, `fromRlpRecord()`
    Rlp2Or17ListEntries
    RlpBlobExpected
    RlpBranchLinkExpected
    RlpExtPathEncoding
    RlpNonEmptyBlobExpected
    RlpEmptyBlobExpected
    RlpRlpException
    RlpOtherException

    # Db record decoder, `fromDbRecord()`
    DbrNilArgument
    DbrUnknown
    DbrTooShort
    DbrBranchTooShort
    DbrBranchSizeGarbled
    DbrBranchInxOutOfRange
    DbrExtTooShort
    DbrExtSizeGarbled
    DbrExtGotLeafPrefix
    DbrLeafSizeGarbled
    DbrLeafGotExtPrefix

    # Db admin data decoder, `fromAristoDb()`
    ADbGarbledSize
    ADbWrongType

    # Db record encoder, `toDbRecord()`
    VtxExPathOverflow
    VtxLeafPathOverflow

    # Converter `asNode()`
    CacheMissingNodekeys

    # Get function `getVtxCascaded()`
    GetVtxNotFound
    GetTagNotFound

    # Path function hikeUp()`
    PathRootMissing
    PathLeafTooEarly
    PathBranchTailEmpty
    PathBranchBlindEdge
    PathExtTailEmpty
    PathExtTailMismatch

    # Memory backend
    MemBeVtxNotFound
    MemBeKeyNotFound

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

    MergeNodeKeyEmpty
    MergeNodeKeyCachedAlready

    # Update `Merkle` hashes `hashify()`
    HashifyCannotComplete
    HashifyCannotHashRoot
    HashifyExistingHashMismatch
    HashifyLeafToRootAllFailed
    HashifyRootHashMismatch
    HashifyRootVidMismatch

    HashifyCheckRevCountMismatch
    HashifyCheckRevHashMismatch
    HashifyCheckRevHashMissing
    HashifyCheckRevVtxDup
    HashifyCheckRevVtxMissing
    HashifyCheckVidVtxMismatch
    HashifyCheckVtxCountMismatch
    HashifyCheckVtxHashMismatch
    HashifyCheckVtxHashMissing
    HashifyCheckVtxIncomplete
    HashifyCheckVtxLockWithoutKey

# End
