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
    AccountRepairBlocked
    DifferentNodeValueExists
    InternalDbInconsistency
    RightBoundaryProofFailed
    Rlp2Or17ListEntries
    RlpBlobExpected
    RlpBranchLinkExpected
    RlpEncoding
    RlpExtPathEncoding
    RlpNonEmptyBlobExpected
    RootNodeMismatch
    RootNodeMissing
    SlotsNotSrictlyIncreasing

    # bulk storage
    AddBulkItemFailed
    CannotOpenRocksDbBulkSession
    CommitBulkItemsFailed
    NoRocksDbBackend
    UnresolvedRepairNode
    OSErrorException

# End

