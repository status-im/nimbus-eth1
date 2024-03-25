# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../../../errors,
  ./base_desc

type
  TxWrapperApiError* = object of CoreDbApiError
    ## For re-routing exception on tx/action template

  CoreDbKvtRef*  = distinct CoreDxKvtRef
  CoreDbMptRef*  = distinct CoreDxMptRef
  CoreDbPhkRef*  = distinct CoreDxPhkRef
  CoreDbTxRef*   = distinct CoreDxTxRef
  CoreDbCaptRef* = distinct CoreDxCaptRef

  CoreDbTrieRefs* = CoreDbMptRef | CoreDbPhkRef
    ## Shortcut, *MPT* modules for (legacy API)

  CoreDbChldRefs* = CoreDbKvtRef | CoreDbTrieRefs | CoreDbTxRef | CoreDbCaptRef
    ## Shortcut, all modules with a `parent` entry (for legacy API)

# End
