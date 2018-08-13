import eth_common, hexstrings

#[
  Notes:
    * Some of the types suppose 'null' when there is no appropriate value.
      To allow for this, currently these values are refs so the JSON transform can convert to `JNull`.
]#

type
  SyncState* = object
    startingBlock*: HexDataStr
    currentBlock*: HexDataStr
    highestBlock*: HexDataStr

  EthSend* = object
    source*: EthAddressStr    # the address the transaction is send from.
    to*: EthAddressStr        # (optional when creating new contract) the address the transaction is directed to.
    gas*: GasInt              # (optional, default: 90000) integer of the gas provided for the transaction execution. It will return unused gas.
    gasPrice*: GasInt         # (optional, default: To-Be-Determined) integer of the gasPrice used for each paid gas.
    value*: int               # (optional) integer of the value sent with this transaction.
    data*: EthHashStr         # TODO: Support more data. The compiled code of a contract OR the hash of the invoked method signature and encoded parameters. For details see Ethereum Contract ABI.
    nonce*: int               # (optional) integer of a nonce. This allows to overwrite your own pending transactions that use the same nonce 

  EthCall* = object  
    source*: EthAddressStr    # (optional) The address the transaction is send from.
    to*: EthAddressStr        # The address the transaction is directed to.
    gas*: GasInt              # (optional) Integer of the gas provided for the transaction execution. eth_call consumes zero gas, but this parameter may be needed by some executions.
    gasPrice*: GasInt         # (optional) Integer of the gasPrice used for each paid gas.
    value*: int               # (optional) Integer of the value sent with this transaction.
    data*: EthHashStr         # (optional) Hash of the method signature and encoded parameters. For details see Ethereum Contract ABI.

  ## A block object, or null when no block was found
  ## Note that this includes slightly different information from eth_common.BlockHeader
  BlockObject* = ref object
    number*: int                    # the block number. null when its pending block.
    hash*: EthHashStr               # hash of the block. null when its pending block.
    parentHash*: EthHashStr         # hash of the parent block.
    nonce*: int64                   # hash of the generated proof-of-work. null when its pending block.
    sha3Uncles*: EthHashStr         # SHA3 of the uncles data in the block.
    logsBloom*: HexDataStr          # the bloom filter for the logs of the block. null when its pending block.
    transactionsRoot*: EthHashStr   # the root of the transaction trie of the block.
    stateRoot*: EthHashStr          # the root of the final state trie of the block.
    receiptsRoot*: EthHashStr       # the root of the receipts trie of the block.
    miner*: EthAddressStr           # the address of the beneficiary to whom the mining rewards were given.
    difficulty*: int                # integer of the difficulty for this block.
    totalDifficulty*: int           # integer of the total difficulty of the chain until this block.
    extraData*: string              # the "extra data" field of this block.
    size*: int                      # integer the size of this block in bytes.
    gasLimit*: int                  # the maximum gas allowed in this block.
    gasUsed*: int                   # the total used gas by all transactions in this block.
    timestamp*: int                 # the unix timestamp for when the block was collated.
    transactions*: seq[EthHashStr]  # list of transaction objects, or 32 Bytes transaction hashes depending on the last given parameter.
    uncles*: seq[EthHashStr]        # list of uncle hashes.

  TransactionObject* = object       # A transaction object, or null when no transaction was found:
    hash*: EthHashStr               # hash of the transaction.
    nonce*: int64                   # TODO: Is int? the number of transactions made by the sender prior to this one.
    blockHash*: EthHashStr          # hash of the block where this transaction was in. null when its pending.
    blockNumber*: HexQuantityStr    # block number where this transaction was in. null when its pending.
    transactionIndex*: int64        # integer of the transactions index position in the block. null when its pending.
    source*: EthAddressStr          # address of the sender.
    to*: EthAddressStr              # address of the receiver. null when its a contract creation transaction.
    value*: int64                   # value transferred in Wei.
    gasPrice*: GasInt               # gas price provided by the sender in Wei.
    gas*: GasInt                    # gas provided by the sender.
    input*: HexDataStr              # the data send along with the transaction.

  LogObject* = object
    removed*: bool                # true when the log was removed, due to a chain reorganization. false if its a valid log.
    logIndex*: int                # integer of the log index position in the block. null when its pending log.
    transactionIndex*: ref int    # integer of the transactions index position log was created from. null when its pending log.
    transactionHash*: EthHashStr  # hash of the transactions this log was created from. null when its pending log.
    blockHash*: ref EthHashStr    # hash of the block where this log was in. null when its pending. null when its pending log.
    blockNumber*: ref HexDataStr  # the block number where this log was in. null when its pending. null when its pending log.
    address*: EthAddressStr       # address from which this log originated.
    data*: seq[EthHashStr]        # contains one or more 32 Bytes non-indexed arguments of the log.
    topics*: array[4, EthHashStr] # array of 0 to 4 32 Bytes DATA of indexed log arguments.
                                  # (In solidity: The first topic is the hash of the signature of the event.
                                  # (e.g. Deposit(address,bytes32,uint256)), except you declared the event with the anonymous specifier.)
