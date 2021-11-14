# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/strutils,
  eth/[common],
  stew/byteutils,
  stint,
  chronos,
  json_rpc/[rpcclient],
  "."/[vault, client, callsigs]

const
  gasPrice* = 30000000000 # 30 Gwei or 30 * pow(10, 9)
  chainID* = ChainID(7)

type
  TestEnv* = ref object
    vault*: Vault
    client*: RpcClient

func eth(n: int): UInt256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

func u256(x: string): UInt256 =
  UInt256.fromHex(x)

func ethAddr(x: string): EthAddress =
  hexToByteArray[20](x)

# envTest make sure the env is set up properly for subsequent tests
proc envTest*(t: TestEnv): Future[bool] {.async.} =
  let client = t.client
  let res = await client.web3_clientVersion()

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
      debugEcho "expected: $1, got $2" % [x[0], $res]
      return false

  result = true

# balanceAndNonceAtTest creates a new account and transfers funds to it.
# It then tests if the balance and nonce of the sender and receiver
# address are updated correct.
proc balanceAndNonceAtTest*(t: TestEnv) {.async.} =
  let
    sourceAddr  = await t.vault.createAccount(1.eth)
    sourceNonce = 0.AccountNonce
    targetAddr  = await t.vault.createAccount(0.u256)

  # Get current balance
  let sourceAddressBalanceBefore = t.client.balanceAt(sourceAddr)

  # TODO: complete this test
