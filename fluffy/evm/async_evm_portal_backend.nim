# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import ../network/state/state_endpoints, ./async_evm

proc toAsyncEvmStateBackend*(stateNetwork: StateNetwork): AsyncEvmStateBackend =
  let
    accProc = proc(
        stateRoot: Hash32, address: Address
    ): Future[Opt[Account]] {.async: (raw: true, raises: [CancelledError]).} =
      stateNetwork.getAccount(stateRoot, address)
    storageProc = proc(
        stateRoot: Hash32, address: Address, slotKey: UInt256
    ): Future[Opt[UInt256]] {.async: (raw: true, raises: [CancelledError]).} =
      stateNetwork.getStorageAtByStateRoot(stateRoot, address, slotKey)
    codeProc = proc(
        stateRoot: Hash32, address: Address
    ): Future[Opt[seq[byte]]] {.async: (raw: true, raises: [CancelledError]).} =
      stateNetwork.getCodeByStateRoot(stateRoot, address)

  AsyncEvmStateBackend.init(accProc, storageProc, codeProc)
