proc eth_chaindId(): HexQuantityStr
proc eth_getBlockByHash(data: EthHashStr, fullTransactions: bool): Option[BlockObject]
proc eth_getBlockByNumber(quantityTag: string, fullTransactions: bool): Option[BlockObject]
proc eth_getBlockTransactionCountByHash(data: EthHashStr): HexQuantityStr
proc eth_getTransactionReceipt(data: Hash256): Option[ReceiptObject]
proc eth_getLogs(filterOptions: FilterOptions): seq[FilterLog]

# Not supported: Only supported by Alchemy
proc eth_getBlockReceipts(data: Hash256): seq[ReceiptObject]
