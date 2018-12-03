## This module contains signatures for the Ethereum client RPCs.
## The signatures are not imported directly, but read and processed with parseStmt,
## then a procedure body is generated to marshal native Nim parameters to json and visa versa.
import json, stint, eth_common, ../../nimbus/rpc/hexstrings, ../../nimbus/rpc/rpc_types

proc web3_clientVersion(): string
proc web3_sha3(data: string): string
proc net_version(): string
proc net_peerCount(): int
proc net_listening(): bool
proc eth_protocolVersion(): string
proc eth_syncing(): JsonNode
proc eth_coinbase(): EthAddressStr
proc eth_mining(): bool
proc eth_hashrate(): int
proc eth_gasPrice(): GasInt
proc eth_accounts(): seq[EthAddressStr]
proc eth_blockNumber(): BlockNumber
proc eth_getBalance(data: EthAddressStr, quantityTag: string): UInt256
proc eth_getStorageAt(data: EthAddressStr, quantity: int, quantityTag: string): seq[byte]
proc eth_getTransactionCount(data: EthAddressStr, quantityTag: string)
proc eth_getBlockTransactionCountByHash(data: array[32, byte])
proc eth_getBlockTransactionCountByNumber(quantityTag: string)
proc eth_getUncleCountByBlockHash(data: array[32, byte])
proc eth_getUncleCountByBlockNumber(quantityTag: string)
proc eth_getCode(data: EthAddressStr, quantityTag: string): HexDataStr
proc eth_sign(data:EthAddressStr, message: HexDataStr): HexDataStr
#proc eth_sendRawTransaction(data: string, quantityTag: int): UInt256
proc eth_call(call: EthCall, quantityTag: string): string
proc eth_estimateGas(call: EthCall, quantityTag: string): GasInt

# TODO: Use eth_common types

#[proc eth_sendTransaction(obj: EthSend): UInt256
proc eth_getBlockByHash(data: array[32, byte], fullTransactions: bool): BlockObject
proc eth_getBlockByNumber(quantityTag: string, fullTransactions: bool): BlockObject
proc eth_getTransactionByHash(data: Uint256): TransactionObject
proc eth_getTransactionByBlockHashAndIndex(data: UInt256, quantity: int): TransactionObject
proc eth_getTransactionByBlockNumberAndIndex(quantityTag: string, quantity: int): TransactionObject
proc eth_getTransactionReceipt(data: UInt256): ReceiptObject
proc eth_getUncleByBlockHashAndIndex(data: UInt256, quantity: int64): BlockObject
proc eth_getUncleByBlockNumberAndIndex(quantityTag: string, quantity: int64): BlockObject
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
proc shh_post(): string
proc shh_version(message: WhisperPost): bool
proc shh_newIdentity(): array[60, byte]
proc shh_hasIdentity(identity: array[60, byte]): bool
proc shh_newGroup(): array[60, byte]
proc shh_addToGroup(identity: array[60, byte]): bool
proc shh_newFilter(filterOptions: FilterOptions, to: array[60, byte], topics: seq[UInt256]): int
proc shh_uninstallFilter(id: int): bool
proc shh_getFilterChanges(id: int): seq[WhisperMessage]
proc shh_getMessages(id: int): seq[WhisperMessage]
]#