# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/[common, p2p],
  "."/[hexary_desc, snapdb_desc, snapdb_persistent]

type
  SnapDbContractsRef* = ref object of SnapDbBaseRef
    peer: Peer               ## For log messages

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getContractsFn*(desc: SnapDbBaseRef|SnapDbRef): HexaryGetFn =
  ## Return `HexaryGetFn` closure.
  let getFn = desc.kvDb.persistentContractsGetFn()
  return proc(key: openArray[byte]): Blob = getFn(key)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
