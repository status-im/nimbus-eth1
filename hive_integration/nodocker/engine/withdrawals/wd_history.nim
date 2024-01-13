# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[tables, sets, strutils],
  eth/common/eth_types,
  json_rpc/[rpcclient],
  stew/[byteutils, results],
  ../engine_client,
  ../../../nimbus/utils/utils,
  ../../../nimbus/beacon/web3_eth_conv

type
  Withdrawals* = ref object
    list*: seq[Withdrawal]

  # Helper structure used to keep history of the amounts
  # withdrawn to each test account.
  WDHistory* = object
    map: Table[uint64, Withdrawals]

proc put*(wh: var WDHistory, blockNumber: uint64, wds: openArray[Withdrawal]) =
  wh.map[blockNumber] = Withdrawals(
    list: @wds
  )

proc get*(wh: WDHistory, blockNumber: uint64): Result[seq[Withdrawal], string] =
  let wds = wh.map.getOrDefault(blockNumber)
  if wds.isNil:
    return err("withdrawal not found in block " & $blockNumber)
  ok(wds.list)

# Gets an account expected value for a given block, taking into account all
# withdrawals that credited the account.
func getExpectedAccountBalance*(wh: WDHistory, account: EthAddress, blockNumber: uint64): UInt256 =
  for b in 0..blockNumber:
    let wds = wh.map.getOrDefault(b)
    if wds.isNil: continue
    for wd in wds.list:
      if wd.address == account:
        result += wd.weiAmount

# Get a list of all addresses that were credited by withdrawals on a given block.
func getAddressesWithdrawnOnBlock*(wh: WDHistory, blockNumber: uint64): seq[EthAddress] =
  var addressMap: HashSet[EthAddress]
  let wds = wh.map.getOrDefault(blockNumber)
  if wds.isNil.not:
    for wd in wds.list:
      addressMap.incl wd.address

  for address in addressMap:
    result.add address

# Get the withdrawals list for a given block.
func getWithdrawals*(wh: WDHistory, blockNumber: uint64): Withdrawals =
  let wds = wh.map.getOrDefault(blockNumber)
  if wds.isNil:
    Withdrawals()
  else:
    wds

# Get the withdrawn accounts list until a given block height.
func getWithdrawnAccounts*(wh: WDHistory, blockHeight: uint64): Table[EthAddress, UInt256] =
  for blockNumber in 0..blockHeight:
    let wds = wh.map.getOrDefault(blockNumber)
    if wds.isNil: continue
    for wd in wds.list:
      result.withValue(wd.address, value) do:
        value[] += wd.weiAmount
      do:
        result[wd.address] = wd.weiAmount

# Verify all withdrawals on a client at a given height
proc verifyWithdrawals*(wh: WDHistory, blockNumber: uint64, rpcBlock: Option[UInt256], client: RpcClient): Result[void, string] =
  let accounts = wh.getWithdrawnAccounts(blockNumber)
  for account, expectedBalance in accounts:
    let res =  if rpcBlock.isSome:
                 client.balanceAt(account, rpcBlock.get)
               else:
                 client.balanceAt(account)
    res.expectBalanceEqual(account, expectedBalance)

    # All withdrawals account have a bytecode that unconditionally set the
    # zero storage key to one on EVM execution.
    # Withdrawals must not trigger EVM so we expect zero.
    let s = if rpcBlock.isSome:
              client.storageAt(account, 0.u256, rpcBlock.get)
            else:
              client.storageAt(account, 0.u256)
    s.expectStorageEqual(account, 0.u256.w3FixedBytes)
  ok()

# Create a new copy of the withdrawals history
func copy*(wh: WDHistory): WDHistory =
  for k, v in wh.map:
    result.map[k] = v
