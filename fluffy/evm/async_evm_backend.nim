# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import chronos, stint, eth/common/[headers, addresses, accounts]

export chronos, stint, headers, addresses, accounts

type
  GetAccountProc* = proc(header: Header, address: Address): Future[Opt[Account]] {.
    async: (raises: [CancelledError])
  .}

  GetStorageProc* = proc(
    header: Header, address: Address, slotKey: UInt256
  ): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).}

  GetCodeProc* = proc(header: Header, address: Address): Future[Opt[seq[byte]]] {.
    async: (raises: [CancelledError])
  .}

  AsyncEvmStateBackend* = ref object
    getAccount*: GetAccountProc
    getStorage*: GetStorageProc
    getCode*: GetCodeProc

proc init*(
    T: type AsyncEvmStateBackend,
    accProc: GetAccountProc,
    storageProc: GetStorageProc,
    codeProc: GetCodeProc,
): T =
  AsyncEvmStateBackend(getAccount: accProc, getStorage: storageProc, getCode: codeProc)
