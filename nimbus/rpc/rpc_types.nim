import eth_common, hexstrings

#[
  Notes:
    * Some of the types suppose 'null' when there is no appropriate value.
      To allow for this, currently these values are refs so the JSON transform can convert to `JNull`.
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
  BlockObject* = ref object
    # Returned to user
    number*: ref BlockNumber        # the block number. null when its pending block.
    hash*: ref Hash256              # hash of the block. null when its pending block.
    parentHash*: Hash256            # hash of the parent block.
    nonce*: uint64                  # hash of the generated proof-of-work. null when its pending block.
    sha3Uncles*: Hash256            # SHA3 of the uncles data in the block.
    logsBloom*: ref BloomFilter     # the bloom filter for the logs of the block. null when its pending block.
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
    uncles*: seq[BlockHeader]       # list of uncle hashes.

  TransactionObject* = object       # A transaction object, or null when no transaction was found:
    # Returned to user
    hash*: Hash256                  # hash of the transaction.
    nonce*: uint64                  # the number of transactions made by the sender prior to this one.
    blockHash*: ref Hash256         # hash of the block where this transaction was in. null when its pending.
    blockNumber*: ref BlockNumber   # block number where this transaction was in. null when its pending.
    transactionIndex*: ref int64    # integer of the transactions index position in the block. null when its pending.
    source*: EthAddress             # address of the sender.
    to*: ref EthAddress             # address of the receiver. null when its a contract creation transaction.
    value*: int64                   # value transferred in Wei.
    gasPrice*: GasInt               # gas price provided by the sender in Wei.
    gas*: GasInt                    # gas provided by the sender.
    input*: Blob                    # the data send along with the transaction.

  LogObject* = object
    # Returned to user
    removed*: bool                # true when the log was removed, due to a chain reorganization. false if its a valid log.
    logIndex*: ref int            # integer of the log index position in the block. null when its pending log.
    transactionIndex*: ref int    # integer of the transactions index position log was created from. null when its pending log.
    transactionHash*: ref Hash256 # hash of the transactions this log was created from. null when its pending log.
    blockHash*: ref Hash256       # hash of the block where this log was in. null when its pending. null when its pending log.
    blockNumber*: ref BlockNumber # the block number where this log was in. null when its pending. null when its pending log.
    address*: EthAddress          # address from which this log originated.
    data*: seq[Hash256]           # contains one or more 32 Bytes non-indexed arguments of the log.
    topics*: array[4, Hash256]    # array of 0 to 4 32 Bytes DATA of indexed log arguments.
                                  # (In solidity: The first topic is the hash of the signature of the event.
                                  # (e.g. Deposit(address,bytes32,uint256)), except you declared the event with the anonymous specifier.)
