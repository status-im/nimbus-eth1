import eth_common, hexstrings, options

#[
  Notes:
    * Some of the types suppose 'null' when there is no appropriate value.
      To allow for this, you can use Option[T] or use refs so the JSON transform can convert to `JNull`.
    * Parameter objects from users must have their data verified so will use EthAddressStr instead of EthAddres, for example
    * Objects returned to the user can use native Nimbus types, where hexstrings provides converters to hex strings.
      This is because returned arrays in JSON is
      a) not an efficient use of space
      b) not the format the user expects (for example addresses are expected to be hex strings prefixed by "0x")
]#

type
  SyncState* = object
    # Returned to user
    startingBlock*: BlockNumber
    currentBlock*: BlockNumber
    highestBlock*: BlockNumber

  EthSend* = object
    # Parameter from user
    source*: EthAddressStr    # the address the transaction is send from.
    to*: EthAddressStr        # (optional when creating new contract) the address the transaction is directed to.
    gas*: GasInt              # (optional, default: 90000) integer of the gas provided for the transaction execution. It will return unused gas.
    gasPrice*: GasInt         # (optional, default: To-Be-Determined) integer of the gasPrice used for each paid gas.
    value*: int               # (optional) integer of the value sent with this transaction.
    data*: EthHashStr         # TODO: Support more data. The compiled code of a contract OR the hash of the invoked method signature and encoded parameters. For details see Ethereum Contract ABI.
    nonce*: int               # (optional) integer of a nonce. This allows to overwrite your own pending transactions that use the same nonce 

  EthCall* = object  
    # Parameter from user
    source*: EthAddressStr    # (optional) The address the transaction is send from.
    to*: EthAddressStr        # The address the transaction is directed to.
    gas*: GasInt              # (optional) Integer of the gas provided for the transaction execution. eth_call consumes zero gas, but this parameter may be needed by some executions.
    gasPrice*: GasInt         # (optional) Integer of the gasPrice used for each paid gas.
    value*: int               # (optional) Integer of the value sent with this transaction.
    data*: EthHashStr         # (optional) Hash of the method signature and encoded parameters. For details see Ethereum Contract ABI.

  ## A block object, or null when no block was found
  ## Note that this includes slightly different information from eth_common.BlockHeader
  BlockObject* = object
    # Returned to user
    number*: Option[BlockNumber]    # the block number. null when its pending block.
    hash*: Option[Hash256]          # hash of the block. null when its pending block.
    parentHash*: Hash256            # hash of the parent block.
    nonce*: uint64                  # hash of the generated proof-of-work. null when its pending block.
    sha3Uncles*: Hash256            # SHA3 of the uncles data in the block.
    logsBloom*: Option[BloomFilter] # the bloom filter for the logs of the block. null when its pending block.
    transactionsRoot*: Hash256      # the root of the transaction trie of the block.
    stateRoot*: Hash256             # the root of the final state trie of the block.
    receiptsRoot*: Hash256          # the root of the receipts trie of the block.
    miner*: EthAddress              # the address of the beneficiary to whom the mining rewards were given.
    difficulty*: UInt256            # integer of the difficulty for this block.
    totalDifficulty*: UInt256       # integer of the total difficulty of the chain until this block.
    extraData*: Blob                # the "extra data" field of this block.
    size*: int                      # integer the size of this block in bytes.
    gasLimit*: GasInt               # the maximum gas allowed in this block.
    gasUsed*: GasInt                # the total used gas by all transactions in this block.
    timestamp*: EthTime             # the unix timestamp for when the block was collated.
    transactions*: seq[Transaction] # list of transaction objects, or 32 Bytes transaction hashes depending on the last given parameter.
    uncles*: seq[Hash256]           # list of uncle hashes.

  TransactionObject* = object       # A transaction object, or null when no transaction was found:
    # Returned to user
    hash*: Hash256                    # hash of the transaction.
    nonce*: AccountNonce              # the number of transactions made by the sender prior to this one.
    blockHash*: Option[Hash256]       # hash of the block where this transaction was in. null when its pending.
    blockNumber*: Option[BlockNumber] # block number where this transaction was in. null when its pending.
    transactionIndex*: Option[int64]  # integer of the transactions index position in the block. null when its pending.
    source*: EthAddress               # address of the sender.
    to*: Option[EthAddress]           # address of the receiver. null when its a contract creation transaction.
    value*: UInt256                   # value transferred in Wei.
    gasPrice*: GasInt                 # gas price provided by the sender in Wei.
    gas*: GasInt                      # gas provided by the sender.
    input*: Blob                      # the data send along with the transaction.

  FilterLog* = object
    # Returned to user
    removed*: bool                      # true when the log was removed, due to a chain reorganization. false if its a valid log.
    logIndex*: Option[int]              # integer of the log index position in the block. null when its pending log.
    transactionIndex*: Option[int]      # integer of the transactions index position log was created from. null when its pending log.
    transactionHash*: Option[Hash256]   # hash of the transactions this log was created from. null when its pending log.
    blockHash*: Option[Hash256]         # hash of the block where this log was in. null when its pending. null when its pending log.
    blockNumber*: Option[BlockNumber]   # the block number where this log was in. null when its pending. null when its pending log.
    address*: EthAddress                # address from which this log originated.
    data*: seq[Hash256]                 # contains one or more 32 Bytes non-indexed arguments of the log.
    topics*: array[4, Hash256]          # array of 0 to 4 32 Bytes DATA of indexed log arguments.
                                        # (In solidity: The first topic is the hash of the signature of the event.
                                        # (e.g. Deposit(address,bytes32,uint256)), except you declared the event with the anonymous specifier.)

  ReceiptObject* = object
    # A transaction receipt object, or null when no receipt was found:
    transactionHash*: Hash256             # hash of the transaction.
    transactionIndex*: int                # integer of the transactions index position in the block.
    blockHash*: Hash256                   # hash of the block where this transaction was in.
    blockNumber*: BlockNumber             # block number where this transaction was in.
    sender*: EthAddress                   # address of the sender.
    to*: Option[EthAddress]               # address of the receiver. null when its a contract creation transaction.
    cumulativeGasUsed*: GasInt            # the total amount of gas used when this transaction was executed in the block.
    gasUsed*: GasInt                      # the amount of gas used by this specific transaction alone.
    contractAddress*: Option[EthAddress]  # the contract address created, if the transaction was a contract creation, otherwise null.
    logs*: seq[Log]                       # list of log objects which this transaction generated.
    logsBloom*: BloomFilter               # bloom filter for light clients to quickly retrieve related logs.
    root*: Hash256                        # post-transaction stateroot (pre Byzantium).
    status*: int                          # 1 = success, 0 = failure.

  FilterDataKind* = enum fkItem, fkList
  FilterData* = object
    # Difficult to process variant objects in input data, as kind is immutable.
    # TODO: This might need more work to handle "or" options
    kind*: FilterDataKind
    items*: seq[FilterData]
    item*: UInt256

  FilterOptions* = object
    # Parameter from user
    fromBlock*: string              # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    toBlock*: string                # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    address*: EthAddress            # (optional) contract address or a list of addresses from which logs should originate.
    topics*: seq[FilterData]        # (optional) list of DATA topics. Topics are order-dependent. Each topic can also be a list of DATA with "or" options.

  WhisperPost* = object
    # Parameter from user
    source*: WhisperIdentityStr # (optional) the identity of the sender.
    to*: WhisperIdentityStr     # (optional) the identity of the receiver. When present whisper will encrypt the message so that only the receiver can decrypt it.
    topics*: seq[HexDataStr]    # list of DATA topics, for the receiver to identify messages.
    payload*: HexDataStr        # the payload of the message.
    priority*: int              # integer of the priority in a rang from.
    ttl*: int                   # integer of the time to live in seconds.

  WhisperIdentity = array[60, byte]

  WhisperMessage* = object
    # Returned to user
    hash*: Hash256              # the hash of the message.
    source*: WhisperIdentity    # the sender of the message, if a sender was specified.
    to*: WhisperIdentity        # the receiver of the message, if a receiver was specified.
    expiry*: int                # integer of the time in seconds when this message should expire.
    ttl*: int                   # integer of the time the message should float in the system in seconds.
    sent*: int                  # integer of the unix timestamp when the message was sent.
    topics*: seq[UInt256]       # list of DATA topics the message contained.
    payload*: Blob              # the payload of the message.
    workProved*: int            # integer of the work this message required before it was send.
