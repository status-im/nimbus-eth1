# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module contains signatures for the Ethereum client RPCs.
## The signatures are not imported directly, but read and processed with parseStmt,
## then a procedure body is generated to marshal native Nim parameters to json and visa versa.
import
  json,
  stint, eth/common,
  ../../nimbus/rpc/hexstrings, ../../nimbus/rpc/rpc_types

proc web3_clientVersion(): string
proc web3_sha3(data: HexDataStr): string
proc net_version(): string
proc net_peerCount(): HexQuantityStr
proc net_listening(): bool
proc eth_protocolVersion(): string
proc eth_chainId(): HexQuantityStr
proc eth_syncing(): JsonNode
proc eth_coinbase(): EthAddressStr
proc eth_mining(): bool
proc eth_hashrate(): HexQuantityStr
proc eth_gasPrice(): HexQuantityStr
proc eth_accounts(): seq[EthAddressStr]
proc eth_blockNumber(): HexQuantityStr
proc eth_getBalance(data: EthAddressStr, quantityTag: string): HexQuantityStr
proc eth_getStorageAt(data: EthAddressStr, slot: HexDataStr, quantityTag: string): HexDataStr
proc eth_getTransactionCount(data: EthAddressStr, quantityTag: string): HexQuantityStr
proc eth_getBlockTransactionCountByHash(data: Hash256): HexQuantityStr
proc eth_getBlockTransactionCountByNumber(quantityTag: string): HexQuantityStr
proc eth_getUncleCountByBlockHash(data: Hash256): HexQuantityStr
proc eth_getUncleCountByBlockNumber(quantityTag: string): HexQuantityStr
proc eth_getCode(data: EthAddressStr, quantityTag: string): HexDataStr
proc eth_sign(data: EthAddressStr, message: HexDataStr): HexDataStr
proc eth_signTransaction(data: TxSend): HexDataStr
proc eth_sendTransaction(data: TxSend): EthHashStr
proc eth_sendRawTransaction(data: HexDataStr): EthHashStr
proc eth_call(call: EthCall, quantityTag: string): HexDataStr
proc eth_estimateGas(call: EthCall, quantityTag: string): HexQuantityStr
proc eth_getBlockByHash(data: Hash256, fullTransactions: bool): Option[BlockObject]
proc eth_getBlockByNumber(quantityTag: string, fullTransactions: bool): Option[BlockObject]
proc eth_getTransactionByHash(data: Hash256): Option[TransactionObject]
proc eth_getTransactionByBlockHashAndIndex(data: Hash256, quantity: HexQuantityStr): Option[TransactionObject]
proc eth_getTransactionByBlockNumberAndIndex(quantityTag: string, quantity: HexQuantityStr): Option[TransactionObject]
proc eth_getTransactionReceipt(data: Hash256): Option[ReceiptObject]
proc eth_getUncleByBlockHashAndIndex(data: Hash256, quantity: HexQuantityStr): Option[BlockObject]
proc eth_getUncleByBlockNumberAndIndex(quantityTag: string, quantity: HexQuantityStr): Option[BlockObject]
proc eth_getLogs(filterOptions: FilterOptions): seq[FilterLog]

#[
proc eth_getCompilers(): seq[string]
proc eth_compileLLL(): seq[byte]
proc eth_compileSolidity(): seq[byte]
proc eth_compileSerpent(): seq[byte]
proc eth_newFilter(filterOptions: FilterOptions): int
proc eth_newBlockFilter(): int
proc eth_newPendingTransactionFilter(): int
proc eth_uninstallFilter(filterId: int): bool
proc eth_getFilterChanges(filterId: int): seq[LogObject]
proc eth_getFilterLogs(filterId: int): seq[LogObject]
proc eth_getLogs(filterOptions: FilterOptions): seq[LogObject]
proc eth_getWork(): seq[UInt256]
proc eth_submitWork(nonce: int64, powHash: Uint256, mixDigest: Uint256): bool
proc eth_submitHashrate(hashRate: UInt256, id: Uint256): bool
]#
