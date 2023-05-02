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

    # Rlp decoder, `fromRlpRecord()`
    Rlp2Or17ListEntries
    RlpBlobExpected
    RlpBranchLinkExpected
    RlpExtPathEncoding
    RlpNonEmptyBlobExpected
    RlpEmptyBlobExpected
    RlpRlpException
    RlpOtherException

    # Db record decoder, `toRlpRecord()`
    DbrUnknown
    DbrTooShort
    DbrOffsOutOfRange
    DbrBranchTooShort
    DbrBranchOffsTooSmall
    DbrBranchInxOutOfRange
    DbrExtTooShort
    DbrExtGarbled
    DbrExtGotLeafPrefix
    DbrLeafGotExtPrefix

# End

