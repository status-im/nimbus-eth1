# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Standard interface
## ===============================
##
{.push raises: [].}

import
  aristo/[aristo_api, aristo_constants]
export
  aristo_api, aristo_constants

import
  aristo/aristo_init
export
  MemBackendRef,
  VoidBackendRef,
  finish,
  init

import
  aristo/aristo_nearby
export
  leftPairs, # iterators
  rightPairs,
  rightPairsAccount,
  rightPairsStorage

import
  aristo/aristo_desc/[desc_identifiers, desc_structural]
export
  AristoAccount,
  desc_identifiers,
  `==`

import
  aristo/aristo_desc
export
  AristoDbRef,
  AristoError,
  AristoTxRef,
  isValid

# End
