# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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
  ../../vm_types,
  ../pow

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

    generateWitness: bool ##\
      ## Enable generation of block witness, currently within `persistBlocks()`
      ## function only.

    verifyFrom: BlockNumber ##\
      ## First block to when `extraValidation` will be applied (only
      ## effective if `extraValidation` is true.)

    vmState: BaseVMState
      ## If it's not nil, block validation will use this
      ## If it's nil, a new vmState state will be created.

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc newChain*(com: CommonRef,
               extraValidation: bool, vmState = BaseVMState(nil)): ChainRef =
  ## Constructor for the `Chain` descriptor object.
  ## The argument `extraValidation` enables extra block
  ## chain validation if set `true`.
  ChainRef(
    com: com,
    validateBlock: true,
    extraValidation: extraValidation,
    vmState: vmState,
  )

func newChain*(com: CommonRef): ChainRef =
  ## Constructor for the `Chain` descriptor object. All sub-object descriptors
  ## are initialised with defaults. So is extra block chain validation
  ##  * `enabled` for PoA networks (such as Goerli)
  ##  * `disabled` for non-PaA networks
  let extraValidation = com.consensus == ConsensusType.POS
  ChainRef(
    com: com,
    validateBlock: true,
    extraValidation: extraValidation,
  )

# ------------------------------------------------------------------------------
# Public `Chain` getters
# ------------------------------------------------------------------------------
proc vmState*(c: ChainRef): BaseVMState =
  ## Getter
  c.vmState

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

proc generateWitness*(c: ChainRef): bool =
  ## Getter
  c.generateWitness

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

proc `generateWitness=`*(c: ChainRef; generateWitness: bool) =
  ## Setter. If set `true`, the assignment value `generateWitness` enables
  ## block witness generation.
  c.generateWitness = generateWitness

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
