# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

type
  EVMError* = object of CatchableError
    ## Base error class for all evm errors.

  BlockNotFound* = object of EVMError
    ## The block with the given number/hash does not exist.

  ParentNotFound* = object of EVMError
    ## The parent of a given block does not exist.

  CanonicalHeadNotFound* = object of EVMError
    ## The chain has no canonical head.

  ValidationError* = object of EVMError
    ## Error to signal something does not pass a validation check.

  CoreDbApiError* = object of CatchableError
    ## Errors related to `CoreDB` API
