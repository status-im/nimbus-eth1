# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import std/tables, ../execution_chain/evm/async_evm_backend

type TestEvmState* = ref object
  accounts: Table[Address, Account]
  storage: Table[Address, Table[UInt256, UInt256]]
  code: Table[Address, seq[byte]]
  blockHashes: Table[BlockNumber, Hash32]

proc init*(T: type TestEvmState): T =
  TestEvmState()

proc setAccount*(backend: TestEvmState, address: Address, acc: Account) =
  backend.accounts[address] = acc

proc setStorage*(
    backend: TestEvmState, address: Address, slotKey: UInt256, slotValue: UInt256
) =
  var storage = backend.storage.getOrDefault(address)
  storage[slotKey] = slotValue
  backend.storage[address] = storage

proc setCode*(backend: TestEvmState, address: Address, code: seq[byte]) =
  backend.code[address] = code

proc setBlockHash*(backend: TestEvmState, number: BlockNumber, blockHash: Hash32) =
  backend.blockHashes[number] = blockHash

proc getAccount*(backend: TestEvmState, address: Address): Account =
  backend.accounts.getOrDefault(address)

proc getStorage*(backend: TestEvmState, address: Address, slotKey: UInt256): UInt256 =
  backend.storage.getOrDefault(address).getOrDefault(slotKey)

proc getCode*(backend: TestEvmState, address: Address): seq[byte] =
  backend.code.getOrDefault(address)

proc getBlockHash*(backend: TestEvmState, number: BlockNumber): Hash32 =
  backend.blockHashes.getOrDefault(number)

proc toAsyncEvmStateBackend*(testState: TestEvmState): AsyncEvmStateBackend =
  # header is ignored because TestEvmState only stores a single state
  let
    accProc = proc(
        header: Header, address: Address
    ): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
      Opt.some(testState.getAccount(address))
    storageProc = proc(
        header: Header, address: Address, slotKey: UInt256
    ): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
      Opt.some(testState.getStorage(address, slotKey))
    codeProc = proc(
        header: Header, address: Address
    ): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
      Opt.some(testState.getCode(address))
    blockHashProc = proc(
        header: Header, number: BlockNumber
    ): Future[Opt[Hash32]] {.async: (raises: [CancelledError]).} =
      Opt.some(testState.getBlockHash(number))

  AsyncEvmStateBackend.init(accProc, storageProc, codeProc, blockHashProc)
