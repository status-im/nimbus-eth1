# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

type
  ComError* = enum
    ComNothingSerious
    ComAccountsMaxTooLarge
    ComAccountsMinTooSmall
    ComEmptyAccountsArguments
    ComEmptyRequestArguments
    ComMissingProof
    ComNetworkProblem
    ComNoAccountsForStateRoot
    ComNoByteCodesAvailable
    ComNoDataForProof
    ComNoStorageForAccounts
    ComNoTrieNodesAvailable
    ComResponseTimeout
    ComTooManyByteCodes
    ComTooManyStorageSlots
    ComTooManyTrieNodes

    # Other errors not directly related to communication
    ComInspectDbFailed
    ComImportAccountsFailed

# End
