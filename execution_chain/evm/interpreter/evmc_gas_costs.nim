# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../../common/evmforks,
  evmc/evmc

type
  # The gas cost specification for storage instructions.
  StorageCostSpec = object
    netCost   : bool   # Is this net gas cost metering schedule?
    warmAccess: int16  # Storage warm access cost, YP: G_{warmaccess}
    sset      : int16  # Storage addition cost, YP: G_{sset}
    reset     : int16  # Storage modification cost, YP: G_{sreset}
    clear     : int16  # Storage deletion refund, YP: R_{sclear}

  StorageStoreCost* = object
    gasCost*  : int16
    gasRefund*: int16

  SstoreCosts* = array[evmc_storage_status, StorageStoreCost]

const
  # From EIP-2929
  ColdSloadCost       = 2100
  WarmStorageReadCost = 100

# Table of gas cost specification for storage instructions per EVM revision.
func storageCostSpec(): array[EVMFork, StorageCostSpec] {.compileTime.} =
  # Legacy cost schedule.
  const revs = [
    FkFrontier, FkHomestead, FkTangerine,
    FkSpurious, FkByzantium, FkPetersburg]

  for rev in revs:
    result[rev] = StorageCostSpec(
      netCost: false, warmAccess: 200, sset: 20000, reset: 5000, clear: 15000)

  # Net cost schedule.
  result[FkConstantinople] = StorageCostSpec(
    netCost: true, warmAccess: 200, sset: 20000, reset: 5000, clear: 15000)
  result[FkIstanbul]       = StorageCostSpec(
    netCost: true, warmAccess: 800, sset: 20000, reset: 5000, clear: 15000)
  result[FkBerlin]         = StorageCostSpec(
    netCost: true, warmAccess: WarmStorageReadCost, sset: 20000,
      reset: 5000 - ColdSloadCost, clear: 15000)
  result[FkLondon]         = StorageCostSpec(
    netCost: true, warmAccess: WarmStorageReadCost, sset: 20000,
      reset: 5000 - ColdSloadCost, clear: 4800)

  for fork in FkParis..EVMFork.high:
    result[fork]   = result[FkLondon]

proc legacySStoreCost(e: var SstoreCosts,
                      c: StorageCostSpec) {.compileTime.} =
  e[EVMC_STORAGE_ADDED]             = StorageStoreCost(gasCost: c.sset , gasRefund: 0)
  e[EVMC_STORAGE_DELETED]           = StorageStoreCost(gasCost: c.reset, gasRefund: c.clear)
  e[EVMC_STORAGE_MODIFIED]          = StorageStoreCost(gasCost: c.reset, gasRefund: 0)
  e[EVMC_STORAGE_ASSIGNED]          = e[EVMC_STORAGE_MODIFIED]
  e[EVMC_STORAGE_DELETED_ADDED]     = e[EVMC_STORAGE_ADDED]
  e[EVMC_STORAGE_MODIFIED_DELETED]  = e[EVMC_STORAGE_DELETED]
  e[EVMC_STORAGE_DELETED_RESTORED]  = e[EVMC_STORAGE_ADDED]
  e[EVMC_STORAGE_ADDED_DELETED]     = e[EVMC_STORAGE_DELETED]
  e[EVMC_STORAGE_MODIFIED_RESTORED] = e[EVMC_STORAGE_MODIFIED]

proc netSStoreCost(e: var SstoreCosts,
                    c: StorageCostSpec) {.compileTime.} =
  e[EVMC_STORAGE_ASSIGNED]          = StorageStoreCost(gasCost: c.warmAccess, gasRefund: 0)
  e[EVMC_STORAGE_ADDED]             = StorageStoreCost(gasCost: c.sset      , gasRefund: 0)
  e[EVMC_STORAGE_DELETED]           = StorageStoreCost(gasCost: c.reset     , gasRefund: c.clear)
  e[EVMC_STORAGE_MODIFIED]          = StorageStoreCost(gasCost: c.reset     , gasRefund: 0)
  e[EVMC_STORAGE_DELETED_ADDED]     = StorageStoreCost(gasCost: c.warmAccess, gasRefund: -c.clear)
  e[EVMC_STORAGE_MODIFIED_DELETED]  = StorageStoreCost(gasCost: c.warmAccess, gasRefund: c.clear)
  e[EVMC_STORAGE_DELETED_RESTORED]  = StorageStoreCost(gasCost: c.warmAccess,
    gasRefund: c.reset - c.warmAccess - c.clear)
  e[EVMC_STORAGE_ADDED_DELETED]     = StorageStoreCost(gasCost: c.warmAccess,
    gasRefund: c.sset - c.warmAccess)
  e[EVMC_STORAGE_MODIFIED_RESTORED] = StorageStoreCost(gasCost: c.warmAccess,
    gasRefund: c.reset - c.warmAccess)

proc storageStoreCost(): array[EVMFork, SstoreCosts] {.compileTime.} =
  const tbl = storageCostSpec()
  for rev in EVMFork:
    let c = tbl[rev]
    if not c.netCost: # legacy
      legacySStoreCost(result[rev], c)
    else: # net cost
      netSStoreCost(result[rev], c)

const
  ForkToSstoreCost* = storageStoreCost()
