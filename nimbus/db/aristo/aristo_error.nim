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

# End

