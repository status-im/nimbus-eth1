# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../../fluffy/evm/async_evm, ../../fluffy/evm/async_evm_backend, ./accounts, ../types

export async_evm, async_evm_backend

proc toAsyncEvmStateBackend(vp: VerifiedRpcProxy): AsyncEvmStateBackend =
  let
    accProc = proc(
        header: Header, address: Address
    ): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
      let account = (await vp.getAccount(address, header.number, header.stateRoot)).valueOr:
        return Opt.none(Account)
      return Opt.some(account)

    storageProc = proc(
        header: Header, address: Address, slotKey: UInt256
    ): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
      let storageSlot = (
        await vp.getStorageAt(address, slotKey, header.number, header.stateRoot)
      ).valueOr:
        return Opt.none(UInt256)
      return Opt.some(storageSlot)

    codeProc = proc(
        header: Header, address: Address
    ): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
      let code = (await vp.getCode(address, header.number, header.stateRoot)).valueOr:
        return Opt.none(seq[byte])
      return Opt.some(code)

  AsyncEvmStateBackend.init(accProc, storageProc, codeProc)

proc initEvm*(vp: var VerifiedRpcProxy) =
  vp.evm = AsyncEvm.init(vp.toAsyncEvmStateBackend())
