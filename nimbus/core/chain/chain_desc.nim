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
  ../../evm/types

export
  common

type
  ChainRef* = ref object of RootRef
    com: CommonRef
      ## common block chain configuration
      ## used throughout entire app

    extraValidation: bool ##\
      ## Trigger extra validation, currently within `persistBlocks()`
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

func newChain*(com: CommonRef,
               extraValidation: bool,
               vmState = BaseVMState(nil)): ChainRef =
  ## Constructor for the `Chain` descriptor object.
  ## The argument `extraValidation` enables extra block
  ## chain validation if set `true`.
  ChainRef(
    com: com,
    extraValidation: extraValidation,
    vmState: vmState
  )

proc newChain*(com: CommonRef): ChainRef =
  ## Constructor for the `Chain` descriptor object. All sub-object descriptors
  ## are initialised with defaults. So is extra block chain validation
  let header = com.db.getCanonicalHead().expect("canonical head exists")
  let extraValidation = com.proofOfStake(header)
  return ChainRef(
    com: com,
    extraValidation: extraValidation,
  )
  
# ------------------------------------------------------------------------------
# Public `Chain` getters
# ------------------------------------------------------------------------------
func vmState*(c: ChainRef): BaseVMState =
  ## Getter
  c.vmState

func db*(c: ChainRef): CoreDbRef =
  ## Getter
  c.com.db

func com*(c: ChainRef): CommonRef =
  ## Getter
  c.com

func extraValidation*(c: ChainRef): bool =
  ## Getter
  c.extraValidation

func verifyFrom*(c: ChainRef): BlockNumber =
  ## Getter
  c.verifyFrom

proc currentBlock*(c: ChainRef): Result[Header, string] =
  ## currentBlock retrieves the current head block of the canonical chain.
  ## Ideally the block should be retrieved from the blockchain's internal cache.
  ## but now it's enough to retrieve it from database
  c.db.getCanonicalHead()

# ------------------------------------------------------------------------------
# Public `Chain` setters
# ------------------------------------------------------------------------------

func `extraValidation=`*(c: ChainRef; extraValidation: bool) =
  ## Setter. If set `true`, the assignment value `extraValidation` enables
  ## extra block chain validation.
  c.extraValidation = extraValidation

func `verifyFrom=`*(c: ChainRef; verifyFrom: BlockNumber) =
  ## Setter. The  assignment value `verifyFrom` defines the first block where
  ## validation should start if the `Clique` field `extraValidation` was set
  ## `true`.
  c.verifyFrom = verifyFrom

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
