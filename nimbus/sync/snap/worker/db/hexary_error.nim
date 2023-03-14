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
  HexaryError* = enum
    NothingSerious = 0

    AccountNotFound
    AccountsNotSrictlyIncreasing
    AccountRangesOverlap
    LowerBoundAfterFirstEntry
    LowerBoundProofError
    NodeNotFound
    RlpEncoding
    SlotsNotFound
    SlotsNotSrictlyIncreasing
    TrieLoopAlert
    TrieIsEmpty
    TrieIsLockedForPerusal
    TooManyProcessedChunks
    TooManySlotAccounts
    NoAccountsYet

    # debug
    LeafMaxExceeded
    GarbledNextLeaf

    # range
    LeafNodeExpected
    FailedNextNode

    # nearby/boundary proofs
    NearbyExtensionError
    NearbyBranchError
    NearbyGarbledNode
    NearbyNestingTooDeep
    NearbyUnexpectedNode
    NearbyFailed
    NearbyEmptyPath
    NearbyLeafExpected
    NearbyDanglingLink
    NearbyPathTail

    # envelope
    DecomposeDegenerated
    DecomposeDisjunct

    # import
    DifferentNodeValueExists
    ExpectedNodeKeyDiffers
    Rlp2Or17ListEntries
    RlpBlobExpected
    RlpBranchLinkExpected
    RlpExtPathEncoding
    RlpNonEmptyBlobExpected

    # interpolate
    AccountRepairBlocked
    InternalDbInconsistency
    RightBoundaryProofFailed
    RootNodeMismatch
    RootNodeMissing

    # bulk storage
    AddBulkItemFailed
    CannotOpenRocksDbBulkSession
    CommitBulkItemsFailed
    NoRocksDbBackend
    UnresolvedRepairNode
    OSErrorException
    IOErrorException
    ExceptionError
    StateRootNotFound

# End

