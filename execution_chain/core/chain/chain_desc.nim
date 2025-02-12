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
  ../../common/common

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

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

func newChain*(com: CommonRef,
               extraValidation: bool = true): ChainRef =
  ## Constructor for the `Chain` descriptor object.
  ## The argument `extraValidation` enables extra block
  ## chain validation if set `true`.
  ChainRef(
    com: com,
    extraValidation: extraValidation
  )

# ------------------------------------------------------------------------------
# Public `Chain` getters
# ------------------------------------------------------------------------------

func db*(c: ChainRef): CoreDbRef =
  ## Getter
  c.com.db

func com*(c: ChainRef): CommonRef =
  ## Getter
  c.com

func extraValidation*(c: ChainRef): bool =
  ## Getter
  c.extraValidation

# ------------------------------------------------------------------------------
# Public `Chain` setters
# ------------------------------------------------------------------------------

func `extraValidation=`*(c: ChainRef; extraValidation: bool) =
  ## Setter. If set `true`, the assignment value `extraValidation` enables
  ## extra block chain validation.
  c.extraValidation = extraValidation

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
