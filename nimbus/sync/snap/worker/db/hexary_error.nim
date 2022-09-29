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
  HexaryDbError* = enum
    NothingSerious = 0

    AccountNotFound
    AccountSmallerThanBase
    AccountsNotSrictlyIncreasing
    AccountRangesOverlap
    RlpEncoding
    SlotsNotSrictlyIncreasing
    TrieLoopAlert
    TrieIsEmpty

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

# End

