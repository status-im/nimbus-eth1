# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  eth/common/addresses,
  stew/byteutils,
  ../db/ledger

const
  FactoryAddress = address"0x4e59b44847b379578588920cA78FbF26c0B4956C"
  FactoryCode = hexToSeqByte"0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"

proc applyEip7997*(ledger: LedgerRef) =
  # EIP-7997: seed the factory with nonce 1 and its runtime code, but only when
  # it isn't already present. Per the EIP this is a no-op on chains that already
  # have the factory; resetting an existing (possibly already-used) factory's
  # nonce would corrupt the state root at the transition block.
  if ledger.getCodeSize(FactoryAddress) == 0:
    let factoryCode = FactoryCode
    ledger.setCode(FactoryAddress, factoryCode)
    ledger.setNonce(FactoryAddress, 1)
