# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  chronicles,
  ../../execution_chain/evm/async_evm_backend,
  ../../execution_chain/evm/async_evm,
  ./accounts,
  ./header_store,
  ./types

logScope:
  topics = "verified_proxy_evm"

export async_evm, async_evm_backend

proc toAsyncEvmStateBackend*(engine: RpcVerificationEngine): AsyncEvmStateBackend =
  let
    accProc = proc(
        header: Header, address: Address
    ): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
      let account =
        try:
          (await engine.getAccount(address, header.number, header.stateRoot))
        except CatchableError:
          error "error getting account"
          return Opt.none(Account)

      if account.isOk():
        return Opt.some(account.get())

      Opt.none(Account)

    storageProc = proc(
        header: Header, address: Address, slotKey: UInt256
    ): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
      let storageSlot =
        try:
          (await engine.getStorageAt(address, slotKey, header.number, header.stateRoot))
        except CatchableError:
          error "error getting storage"
          return Opt.none(UInt256)

      if storageSlot.isOk():
        return Opt.some(storageSlot.get())

      Opt.none(UInt256)

    codeProc = proc(
        header: Header, address: Address
    ): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
      let code =
        try:
          (await engine.getCode(address, header.number, header.stateRoot))
        except CatchableError:
          error "error getting code"
          return Opt.none(seq[byte])

      if code.isOk():
        return Opt.some(code.get())

      Opt.none(seq[byte])

    blockHashProc = proc(
        header: Header, number: BlockNumber
    ): Future[Opt[Hash32]] {.async: (raises: [CancelledError]).} =
      engine.headerStore.getHash(number)

  AsyncEvmStateBackend.init(accProc, storageProc, codeProc, blockHashProc)
