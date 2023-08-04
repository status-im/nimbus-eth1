# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../../common/common,
  ../../utils/utils,
  ../pow,
  ../clique

export
  common

type
  ChainRef* = ref object of RootRef
    com: CommonRef
      ## common block chain configuration
      ## used throughout entire app

    validateBlock: bool ##\
      ## If turn off, `persistBlocks` will always return
      ## ValidationResult.OK and disable extraValidation too.

    extraValidation: bool ##\
      ## Trigger extra validation, currently within `persistBlocks()`
      ## function only.

    verifyFrom: BlockNumber ##\
      ## First block to when `extraValidation` will be applied (only
      ## effective if `extraValidation` is true.)

# ------------------------------------------------------------------------------
# Private constructor helper
# ------------------------------------------------------------------------------

proc initChain(c: ChainRef; com: CommonRef; extraValidation: bool) =
  ## Constructor for the `Chain` descriptor object.
  c.com = com

  c.validateBlock = true
  c.extraValidation = extraValidation

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc newChain*(com: CommonRef, extraValidation: bool): ChainRef =
  ## Constructor for the `Chain` descriptor object.
  ## The argument `extraValidation` enables extra block
  ## chain validation if set `true`.
  new result
  result.initChain(com, extraValidation)

proc newChain*(com: CommonRef): ChainRef =
  ## Constructor for the `Chain` descriptor object. All sub-object descriptors
  ## are initialised with defaults. So is extra block chain validation
  ##  * `enabled` for PoA networks (such as Goerli)
  ##  * `disabled` for non-PaA networks
  new result
  result.initChain(com, com.consensus == ConsensusType.POA)

# ------------------------------------------------------------------------------
# Public `Chain` getters
# ------------------------------------------------------------------------------
proc clique*(c: ChainRef): Clique =
  ## Getter
  c.com.poa

proc pow*(c: ChainRef): PowRef =
  ## Getter
  c.com.pow

proc db*(c: ChainRef): CoreDbRef =
  ## Getter
  c.com.db

proc com*(c: ChainRef): CommonRef =
  ## Getter
  c.com

proc validateBlock*(c: ChainRef): bool =
  ## Getter
  c.validateBlock

proc extraValidation*(c: ChainRef): bool =
  ## Getter
  c.extraValidation

proc verifyFrom*(c: ChainRef): BlockNumber =
  ## Getter
  c.verifyFrom

proc currentBlock*(c: ChainRef): BlockHeader
  {.gcsafe, raises: [CatchableError].} =
  ## currentBlock retrieves the current head block of the canonical chain.
  ## Ideally the block should be retrieved from the blockchain's internal cache.
  ## but now it's enough to retrieve it from database
  c.db.getCanonicalHead()

# ------------------------------------------------------------------------------
# Public `Chain` setters
# ------------------------------------------------------------------------------
proc `validateBlock=`*(c: ChainRef; validateBlock: bool) =
  ## Setter. If set `true`, the assignment value `validateBlock` enables
  ## block execution, else it will always return ValidationResult.OK
  c.validateBlock = validateBlock

proc `extraValidation=`*(c: ChainRef; extraValidation: bool) =
  ## Setter. If set `true`, the assignment value `extraValidation` enables
  ## extra block chain validation.
  c.extraValidation = extraValidation

proc `verifyFrom=`*(c: ChainRef; verifyFrom: BlockNumber) =
  ## Setter. The  assignment value `verifyFrom` defines the first block where
  ## validation should start if the `Clique` field `extraValidation` was set
  ## `true`.
  c.verifyFrom = verifyFrom

proc `verifyFrom=`*(c: ChainRef; verifyFrom: uint64) =
  ## Variant of `verifyFrom=`
  c.verifyFrom = verifyFrom.u256

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
