# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

type
  EVMFork* = enum
    FkFrontier
    FkHomestead
    FkTangerine
    FkSpurious
    FkByzantium
    FkConstantinople
    FkPetersburg
    FkIstanbul
    FkBerlin
    FkLondon
    FkParis
    FkShanghai
    FkCancun
    FkPrague
    FkOsaka
    FkAmsterdam
    FkBogota

const
  FkLatest* = EVMFork.high

template clearEmptyAccounts*(fork: EVMFork): bool =
  ## EIP-161: Clear empty accounts that were touched by a transaction.
  fork >= FkSpurious

template checkEmptyAccount*(fork: EVMFork): bool =
  ## EIP-7523: After the merge there are no more empty account checks so we no
  ## longer need to check for empty accounts when adding balance to an account.
  fork < FkParis
