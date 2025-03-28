# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import std/tables, ../../evm/async_evm

type TestEvmState* = ref object
  accounts: Table[Address, Account]
  storage: Table[Address, Table[UInt256, UInt256]]
  code: Table[Address, seq[byte]]

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

proc getAccount*(backend: TestEvmState, address: Address): Account =
  backend.accounts.getOrDefault(address)

proc getStorage*(backend: TestEvmState, address: Address, slotKey: UInt256): UInt256 =
  backend.storage.getOrDefault(address).getOrDefault(slotKey)

proc getCode*(backend: TestEvmState, address: Address): seq[byte] =
  backend.code.getOrDefault(address)

proc toAsyncEvmStateBackend*(testState: TestEvmState): AsyncEvmStateBackend =
  # State root is ignored because TestEvmState only stores a single state
  let
    accProc = proc(
        stateRoot: Hash32, address: Address
    ): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
      Opt.some(testState.getAccount(address))
    storageProc = proc(
        stateRoot: Hash32, address: Address, slotKey: UInt256
    ): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
      Opt.some(testState.getStorage(address, slotKey))
    codeProc = proc(
        stateRoot: Hash32, address: Address
    ): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
      Opt.some(testState.getCode(address))

  AsyncEvmStateBackend.init(accProc, storageProc, codeProc)
