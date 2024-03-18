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
  ./base_desc

type
  CoreDxTrieRefs* = CoreDbCtxRef | CoreDxMptRef | CoreDxPhkRef | CoreDxAccRef
    ## Shortcut, *MPT* descriptors

  CoreDxTrieRelated* = CoreDxTrieRefs | CoreDxTxRef | CoreDxCaptRef
    ## Shortcut, descriptors for sub-modules running on an *MPT*

  CoreDbBackends* = CoreDbBackendRef | CoreDbKvtBackendRef |
                    CoreDbMptBackendRef | CoreDbAccBackendRef
    ## Shortcut, all backend descriptors.

  CoreDxChldRefs* = CoreDxKvtRef | CoreDxTrieRelated | CoreDbTrieRef |
                    CoreDbBackends | CoreDbErrorRef
    ## Shortcut, all descriptors with a `parent` entry.

# End
