proc eth_chaindId(): HexQuantityStr
proc eth_getBlockByHash(data: EthHashStr, fullTransactions: bool): Option[BlockObject]
proc eth_getBlockByNumber(quantityTag: string, fullTransactions: bool): Option[BlockObject]
proc eth_getBlockTransactionCountByHash(data: EthHashStr): HexQuantityStr
proc eth_getLogs(filterOptions: FilterOptions): seq[FilterLog]
