# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  ./blocks,
  ./types

logScope:
  topics = "vp_evm"

export async_evm, async_evm_backend

proc toAsyncEvmStateBackend*(engine: RpcVerificationEngine): AsyncEvmStateBackend =
  let
    accProc = proc(
        header: Header, address: Address
    ): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
      let account = (await engine.getAccount(address, header.number, header.stateRoot)).valueOr:
        return Opt.none(Account)

      return Opt.some(account)

    storageProc = proc(
        header: Header, address: Address, slotKeys: seq[UInt256]
    ): Future[Opt[seq[UInt256]]] {.async: (raises: [CancelledError]).} =
      let storageSlots = (
        await engine.getStorageAt(address, slotKeys, header.number, header.stateRoot)
      ).valueOr:
        debug "Storage slots fetch failed",
          address = $address,
          count = slotKeys.len(),
          errType = error.errType,
          errMsg = error.errMsg
        return Opt.none(seq[UInt256])

      Opt.some(storageSlots)

    codeProc = proc(
        header: Header, address: Address
    ): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
      let code = (await engine.getCode(address, header.number, header.stateRoot)).valueOr:
        return Opt.none(seq[byte])

      Opt.some(code)

    blockHashProc = proc(
        header: Header, number: BlockNumber
    ): Future[Opt[Hash32]] {.async: (raises: [CancelledError]).} =
      let blockHash = (await engine.getBlockHash(header, number)).valueOr:
        return Opt.none(Hash32)

      Opt.some(blockHash)

  AsyncEvmStateBackend.init(accProc, storageProc, codeProc, blockHashProc)
