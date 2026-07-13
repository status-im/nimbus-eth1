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
  eth/common/[addresses, hashes],
  stew/byteutils,
  ../db/[core_db, ledger]

const
  FactoryAddress = address"0x4e59b44847b379578588920cA78FbF26c0B4956C"
  FactoryCode = hexToSeqByte"0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
  FactoryCodeHash = hashes.keccak256(FactoryCode)

proc applyEip7997*(ledger: LedgerRef) =
  # Use txFrame directly rather than through the ledger API: with witness
  # collection enabled a ledger read would record the account as a witness access.
  let acc = ledger.txFrame.fetchAccount(FactoryAddress.computeAccPath)
  if acc.isOk and acc.value.codeHash == FactoryCodeHash:
    # It's a no-op on chain that already have factory at the FactoryAddress.
    return

  # Although this code only called once during fork transition,
  # if using the constant above, sometimes it will crash
  # when interacting with CodeBytesRef sink in test environment.
  # Note: Also the accesses here should not be recorded in the witness,
  # however actually deploying the factory code is not supported in
  # combination with stateless at the moment.
  let factoryCode = FactoryCode
  ledger.setCode(FactoryAddress, factoryCode)
  ledger.setNonce(FactoryAddress, 1)
