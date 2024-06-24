# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/strutils,
  eth/common,
  stew/byteutils,
  stint,
  chronos,
  unittest2,
  json_rpc/[rpcclient],
  "."/[vault, client, test_env]

export client

type
  TestSpec* = object
    name*: string
    run*: proc(t: TestEnv): Future[TestStatus]

func eth(n: int): UInt256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

func u256(x: string): UInt256 =
  UInt256.fromHex(x)

func ethAddr(x: string): EthAddress =
  hexToByteArray[20](x)

# envTest make sure the env is set up properly for subsequent tests
proc envTest(t: TestEnv): Future[TestStatus] {.async.} =
  let client = t.rpcClient

  const kv = {
    "cf49fda3be353c69b41ed96333cd24302da4556f": "0x123450000000000000000",
    "0161e041aad467a890839d5b08b138c1e6373072": "0x123450000000000000000",
    "87da6a8c6e9eff15d703fc2773e32f6af8dbe301": "0x123450000000000000000",
    "b97de4b8c857e4f6bc354f226dc3249aaee49209": "0x123450000000000000000",
    "c5065c9eeebe6df2c2284d046bfc906501846c51": "0x123450000000000000000"
  }

  for x in kv:
    let res = await client.balanceAt(ethAddr(x[0]))
    let expected = u256(x[1])
    if res != expected:
      echo "expected: $1, got $2" % [x[1], $res]
      return TestStatus.Failed

  result = TestStatus.OK

# balanceAndNonceAtTest creates a new account and transfers funds to it.
# It then tests if the balance and nonce of the sender and receiver
# address are updated correct.
proc balanceAndNonceAtTest(t: TestEnv): Future[TestStatus] {.async.} =
  let
    client = t.rpcClient
    vault  = t.vault
    sourceAddr  = await vault.createAccount(1.eth)
    targetAddr  = await vault.createAccount(0.u256)

  var
    sourceNonce = 0.AccountNonce

  # Get current balance
  let sourceAddressBalanceBefore = await client.balanceAt(sourceAddr)

  let expected = 1.eth
  if sourceAddressBalanceBefore != expected:
    echo "Expected balance $1, got $1" % [$expected, $sourceAddressBalanceBefore]
    return TestStatus.Failed

  let nonceBefore = await client.nonceAt(sourceAddr)
  if nonceBefore != sourceNonce:
    echo "Invalid nonce, want $1, got $1" % [$sourceNonce, $nonceBefore]
    return TestStatus.Failed

  # send 1234 wei to target account and verify balances and nonces are updated
  let
    amount   = 1234.u256
    gasLimit = 50000.GasInt

  let tx = vault.signTx(sourceAddr, sourceNonce, targetAddr, amount, gasLimit, gasPrice)
  inc sourceNonce

  let txHash = rlpHash(tx)
  echo "BalanceAt: send $1 wei from 0x$2 to 0x$3 in 0x$4" % [
    $tx.tx.value, sourceAddr.toHex, targetAddr.toHex, txHash.data.toHex]

  let ok = await client.sendTransaction(tx)
  if not ok:
    echo "failed to send transaction"
    return TestStatus.Failed

  var gasUsed: GasInt
  var loop = 0
  while true:
    let res = await client.gasUsed(txHash)
    if res.isSome:
      gasUsed = res.get()
      break

    let period = chronos.seconds(1)
    await sleepAsync(period)
    inc loop
    if loop == 5:
      echo "get gas used timeout"
      return TestStatus.Failed

  # ensure balances have been updated
  let accountBalanceAfter = await client.balanceAt(sourceAddr)
  let balanceTargetAccountAfter = await client.balanceAt(targetAddr)

  # expected balance is previous balance - tx amount - tx fee (gasUsed * gasPrice)
  let exp =
    sourceAddressBalanceBefore - amount - (gasUsed * tx.tx.gasPrice).u256

  if exp != accountBalanceAfter:
    echo "Expected sender account to have a balance of $1, got $2" % [$exp, $accountBalanceAfter]
    return TestStatus.Failed

  if balanceTargetAccountAfter != amount:
    echo "Expected new account to have a balance of $1, got $2" % [
      $tx.tx.value, $balanceTargetAccountAfter]
    return TestStatus.Failed

  # ensure nonce is incremented by 1
  let nonceAfter = await client.nonceAt(sourceAddr)
  let expectedNonce = nonceBefore + 1

  if expectedNonce != nonceAfter:
    echo "Invalid nonce, want $1, got $2" % [$expectedNonce, $nonceAfter]
    return TestStatus.Failed

  result = TestStatus.OK

const testList* = [
  TestSpec(
    name: "env is set up properly for subsequent tests",
    run: envTest
  ),
  TestSpec(
    name: "balance and nonce update correctly",
    run: balanceAndNonceAtTest
  )
]
