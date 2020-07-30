import
  hexstrings, options, eth/[common, keys, rlp], json,
  eth/p2p/rlpx_protocols/whisper_protocol

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
    startingBlock*: HexQuantityStr # BlockNumber
    currentBlock* : HexQuantityStr # BlockNumber
    highestBlock* : HexQuantityStr # BlockNumber

  TxSend* = object
    # Parameter from user
    source*: EthAddressStr            # 20 bytes, the address the transaction is send from.
    to*: Option[EthAddressStr]        # (optional when creating new contract) 20 bytes, the address the transaction is directed to.
    gas*: Option[HexQuantityStr]      # (optional, default: 90000) integer of the gas provided for the transaction execution. It will return unused gas.
    gasPrice*: Option[HexQuantityStr] # (optional, default: To-Be-Determined) integer of the gasPrice used for each paid gas.
    value*: Option[HexQuantityStr]    # (optional) integer of the value sent with this transaction.
    data*: HexDataStr                 # TODO: Support more data. The compiled code of a contract OR the hash of the invoked method signature and encoded parameters. For details see Ethereum Contract ABI.
    nonce*: Option[HexQuantityStr]    # (optional) integer of a nonce. This allows to overwrite your own pending transactions that use the same nonce

  EthCall* = object
    # Parameter from user
    source*: Option[EthAddressStr]   # (optional) The address the transaction is send from.
    to*: Option[EthAddressStr]       # (optional in eth_estimateGas, not in eth_call) The address the transaction is directed to.
    gas*: Option[HexQuantityStr]# (optional) Integer of the gas provided for the transaction execution. eth_call consumes zero gas, but this parameter may be needed by some executions.
    gasPrice*: Option[HexQuantityStr]# (optional) Integer of the gasPrice used for each paid gas.
    value*: Option[HexQuantityStr]   # (optional) Integer of the value sent with this transaction.
    data*: Option[EthHashStr]        # (optional) Hash of the method signature and encoded parameters. For details see Ethereum Contract ABI.

  ## A block object, or null when no block was found
  ## Note that this includes slightly different information from eth/common.BlockHeader
  BlockObject* = object
    # Returned to user
    number*: Option[HexQuantityStr] # the block number. null when its pending block.
    hash*: Option[Hash256]          # hash of the block. null when its pending block.
    parentHash*: Hash256            # hash of the parent block.
    nonce*: Option[HexDataStr]      # hash of the generated proof-of-work. null when its pending block.
    sha3Uncles*: Hash256            # SHA3 of the uncles data in the block.
    logsBloom*: Option[BloomFilter] # the bloom filter for the logs of the block. null when its pending block.
    transactionsRoot*: Hash256      # the root of the transaction trie of the block.
    stateRoot*: Hash256             # the root of the final state trie of the block.
    receiptsRoot*: Hash256          # the root of the receipts trie of the block.
    miner*: EthAddress              # the address of the beneficiary to whom the mining rewards were given.
    difficulty*: HexQuantityStr     # integer of the difficulty for this block.
    totalDifficulty*: HexQuantityStr# integer of the total difficulty of the chain until this block.
    extraData*: HexDataStr          # the "extra data" field of this block.
    size*: HexQuantityStr           # integer the size of this block in bytes.
    gasLimit*: HexQuantityStr       # the maximum gas allowed in this block.
    gasUsed*: HexQuantityStr        # the total used gas by all transactions in this block.
    timestamp*: HexQuantityStr      # the unix timestamp for when the block was collated.
    transactions*: seq[JsonNode]    # list of transaction objects, or 32 Bytes transaction hashes depending on the last given parameter.
    uncles*: seq[Hash256]           # list of uncle hashes.

  TransactionObject* = object       # A transaction object, or null when no transaction was found:
    # Returned to user
    blockHash*: Option[Hash256]       # hash of the block where this transaction was in. null when its pending.
    blockNumber*: Option[HexQuantityStr] # block number where this transaction was in. null when its pending.
    `from`*: EthAddress               # address of the sender.
    gas*: HexQuantityStr              # gas provided by the sender.
    gasPrice*: HexQuantityStr         # gas price provided by the sender in Wei.
    hash*: Hash256                    # hash of the transaction.
    input*: Blob                      # the data send along with the transaction.
    nonce*: HexQuantityStr            # the number of transactions made by the sender prior to this one.
    to*: Option[EthAddress]           # address of the receiver. null when its a contract creation transaction.
    transactionIndex*: Option[HexQuantityStr] # integer of the transactions index position in the block. null when its pending.
    value*: HexQuantityStr            # value transferred in Wei.
    v*: HexQuantityStr                # ECDSA recovery id
    r*: HexQuantityStr                # 32 Bytes - ECDSA signature r
    s*: HexQuantityStr                # 32 Bytes - ECDSA signature s

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
    transactionIndex*: HexQuantityStr     # integer of the transactions index position in the block.
    blockHash*: Hash256                   # hash of the block where this transaction was in.
    blockNumber*: HexQuantityStr          # block number where this transaction was in.
    `from`*: EthAddress                   # address of the sender.
    to*: Option[EthAddress]               # address of the receiver. null when its a contract creation transaction.
    cumulativeGasUsed*: HexQuantityStr    # the total amount of gas used when this transaction was executed in the block.
    gasUsed*: HexQuantityStr              # the amount of gas used by this specific transaction alone.
    contractAddress*: Option[EthAddress]  # the contract address created, if the transaction was a contract creation, otherwise null.
    logs*: seq[Log]                       # list of log objects which this transaction generated.
    logsBloom*: BloomFilter               # bloom filter for light clients to quickly retrieve related logs.
    root*: Option[Hash256]                # post-transaction stateroot (pre Byzantium).
    status*: Option[int]                  # 1 = success, 0 = failure.

  FilterDataKind* = enum fkItem, fkList
  FilterData* = object
    # Difficult to process variant objects in input data, as kind is immutable.
    # TODO: This might need more work to handle "or" options
    kind*: FilterDataKind
    items*: seq[FilterData]
    item*: UInt256

  FilterOptions* = object
    # Parameter from user
    fromBlock*: Option[string]            # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    toBlock*: Option[string]              # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    address*: Option[EthAddress]          # (optional) contract address or a list of addresses from which logs should originate.
    topics*: Option[seq[FilterData]]      # (optional) list of DATA topics. Topics are order-dependent. Each topic can also be a list of DATA with "or" options.

  WhisperInfo* = object
    # Returned to user
    minPow*: float64        # Current minimum PoW requirement.
    # TODO: may be uint32
    maxMessageSize*: uint64 # Current message size limit in bytes.
    memory*: int            # Memory size of the floating messages in bytes.
    messages*: int          # Number of floating messages.

  WhisperFilterOptions* = object
    # Parameter from user
    symKeyID*: Option[Identifier]         # ID of symmetric key for message decryption.
    privateKeyID*: Option[Identifier]     # ID of private (asymmetric) key for message decryption.
    sig*: Option[PublicKey]               # (Optional) Public key of the signature.
    minPow*: Option[float64]              # (Optional) Minimal PoW requirement for incoming messages.
    topics*: Option[seq[whisper_protocol.Topic]] # (Optional when asym key): Array of possible topics (or partial topics).
    allowP2P*: Option[bool]               # (Optional) Indicates if this filter allows processing of direct peer-to-peer messages.

  WhisperFilterMessage* = object
    # Returned to user
    sig*: Option[PublicKey]                 # Public key who signed this message.
    recipientPublicKey*: Option[PublicKey]  # The recipients public key.
    ttl*: uint64                            # Time-to-live in seconds.
    timestamp*: uint64                      # Unix timestamp of the message generation.
    topic*: whisper_protocol.Topic          # 4 Bytes: Message topic.
    payload*: seq[byte]                     # Decrypted payload.
    padding*: seq[byte]                     # (Optional) Padding (byte array of arbitrary length).
    pow*: float64                           # Proof of work value.
    hash*: Hash                             # Hash of the enveloped message.

  WhisperPostMessage* = object
    # Parameter from user
    symKeyID*: Option[Identifier]     # ID of symmetric key for message encryption.
    pubKey*: Option[PublicKey]        # Public key for message encryption.
    sig*: Option[Identifier]          # (Optional) ID of the signing key.
    ttl*: uint64                      # Time-to-live in seconds.
    topic*: Option[whisper_protocol.Topic] # Message topic (mandatory when key is symmetric).
    payload*: HexDataStr              # Payload to be encrypted.
    padding*: Option[HexDataStr]      # (Optional) Padding (byte array of arbitrary length).
    powTime*: float64                 # Maximal time in seconds to be spent on proof of work.
    powTarget*: float64               # Minimal PoW target required for this message.
    # TODO: EnodeStr
    targetPeer*: Option[string]       # (Optional) Peer ID (for peer-to-peer message only).
