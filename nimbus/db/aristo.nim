# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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

import aristo/[
  aristo_constants, aristo_delete, aristo_fetch, aristo_init, aristo_merge,
  aristo_nearby, aristo_sign, aristo_tx, aristo_utils, aristo_walk]
export
  aristo_constants, aristo_delete, aristo_fetch, aristo_init, aristo_merge,
  aristo_nearby, aristo_sign, aristo_tx, aristo_utils, aristo_walk

import
  aristo/aristo_transcode
export
  append, read, serialise

import
  aristo/aristo_get
export
  getKeyRc

import
  aristo/aristo_path
export
  pathAsBlob

import aristo/aristo_desc/[desc_identifiers, desc_structural]
export
  AristoAccount,
  PayloadRef,
  PayloadType,
  desc_identifiers,
  `==`

import
  aristo/aristo_desc
export
  AristoDbAction,
  AristoDbRef,
  AristoError,
  AristoTxRef,
  forget,
  isValid

# End
