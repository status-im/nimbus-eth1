# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, strutils],
  eth/[common, keys],
  stew/byteutils,
  chronos, stint,
  json_rpc/[rpcclient],
  ../../../nimbus/utils/utils,
  ../../../nimbus/transaction,
  ./client

when false:
  const
    # This is the account that sends vault funding transactions.
    vaultAccountAddr = hextoByteArray[20]("0xcf49fda3be353c69b41ed96333cd24302da4556f")

const
  # Address of the vault in genesis.
  predeployedVaultAddr = hextoByteArray[20]("0000000000000000000000000000000000000315")
  # Number of blocks to wait before funding tx is considered valid.
  vaultTxConfirmationCount = 5

# vault creates accounts for testing and funds them. An instance of the vault contract is
# deployed in the genesis block. When creating a new account using createAccount, the
# account is funded by sending a transaction to this contract.
#
# The purpose of the vault is allowing tests to run concurrently without worrying about
# nonce assignment and unexpected balance changes.
type
  Vault* = ref object
    # This tracks the account nonce of the vault account.
    nonce: AccountNonce
    # Created accounts are tracked in this map.
    accounts: Table[EthAddress, PrivateKey]

    rng: ref HmacDrbgContext
    chainId*: ChainID
    gasPrice: GasInt
    vaultKey: PrivateKey
    client:   RpcClient

proc newVault*(chainID: ChainID, gasPrice: GasInt, client: RpcClient): Vault =
  new(result)
  result.rng      = newRng()
  result.chainId  = chainID
  result.gasPrice = gasPrice
  result.vaultKey = PrivateKey.fromHex("63b508a03c3b5937ceb903af8b1b0c191012ef6eb7e9c3fb7afa94e5d214d376").get()
  result.client   = client

# generateKey creates a new account key and stores it.
proc generateKey*(v: Vault): EthAddress =
  let key = PrivateKey.random(v.rng[])
  let address = toCanonicalAddress(key.toPublicKey)
  v.accounts[address] = key
  address

# nextNonce generates the nonce of a funding transaction.
proc nextNonce*(v: Vault): AccountNonce =
  let nonce = v.nonce
  inc(v.nonce)
  nonce

proc sendSome(
    address: EthAddress, amount: UInt256): List[byte, Limit MAX_CALLDATA_SIZE] =
  const padding = repeat('\0', 12).toBytes
  # makeshift contract ABI construction
  # https://docs.soliditylang.org/en/develop/abi-spec.html
  let h = keccakHash("sendSome(address,uint256)".toBytes)
  doAssert result.add h.data[0..3] # first 4 bytes of hash
  doAssert result.add padding # left pad address
  doAssert result.add address
  doAssert result.add amount.toBytesBE
  doAssert(result.len == 68) # 4 + 32 + 32

proc makeFundingTx*(
    v: Vault, recipient: EthAddress, amount: UInt256): PooledTransaction =
  let unsignedTx = TransactionPayload(
    nonce: v.nextNonce(),
    max_fee_per_gas: v.gasPrice.uint64.u256,
    gas: 75000,
    to: Opt.some(predeployedVaultAddr),
    value: 0.u256,
    input: sendSome(recipient, amount),
    tx_type: Opt.some TxLegacy)
  PooledTransaction(tx: signTransaction(unsignedTx, v.vaultKey, v.chainId))

proc signTx*(
    v: Vault,
    sender: EthAddress,
    nonce: AccountNonce,
    recipient: EthAddress,
    amount: UInt256,
    gasLimit, gasPrice: GasInt,
    payload = List[byte, Limit MAX_CALLDATA_SIZE] @[]): PooledTransaction =
  let
    unsignedTx = TransactionPayload(
      nonce: nonce,
      max_fee_per_gas: gasPrice.uint64.u256,
      gas: gasLimit.uint64,
      to: Opt.some(recipient),
      value: amount,
      input: payload,
      tx_type: Opt.some TxLegacy)
    key = v.accounts[sender]
  PooledTransaction(tx: signTransaction(unsignedTx, key, v.chainId))

# createAccount creates a new account that is funded from the vault contract.
# It will panic when the account could not be created and funded.
proc createAccount*(v: Vault, amount: UInt256): Future[EthAddress] {.async.} =
  let address = v.generateKey()

  # order the vault to send some ether
  let tx = v.makeFundingTx(address, amount)
  let res = await v.client.sendTransaction(tx, v.chainId)
  if not res:
    raise newException(ValueError, "unable to send funding transaction")

  let txBlock = await v.client.blockNumber()

  # wait for vaultTxConfirmationCount confirmation by checking the balance vaultTxConfirmationCount blocks back.
  # createAndFundAccountWithSubscription for a better solution using logs
  let count = vaultTxConfirmationCount*4
  for i in 0..<count:
    let number = await v.client.blockNumber()
    if number > txBlock + vaultTxConfirmationCount:
      let checkBlock = number - vaultTxConfirmationCount
      let balance = await v.client.balanceAt(address, checkBlock)
      if balance >= amount:
        return address

    let period = chronos.seconds(1)
    await sleepAsync(period)

  let txHash = tx.tx.compute_tx_hash(v.chainId).data.toHex
  raise newException(ValueError, "could not fund account $2 in transaction $2" % [address.toHex, txHash])
