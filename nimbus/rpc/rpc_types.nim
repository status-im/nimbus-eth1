import
  json_rpc/jsonmarshal,
  stew/byteutils,
  hexstrings, options, eth/common, json

from
  web3/ethtypes import FixedBytes

export FixedBytes, common

{.push raises: [].}

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
    gas*: Option[HexQuantityStr]     # (optional) Integer of the gas provided for the transaction execution. eth_call consumes zero gas, but this parameter may be needed by some executions.
    gasPrice*: Option[HexQuantityStr]# (optional) Integer of the gasPrice used for each paid gas.
    maxFeePerGas*: Option[HexQuantityStr]         # (optional) MaxFeePerGas is the maximum fee per gas offered, in wei.
    maxPriorityFeePerGas*: Option[HexQuantityStr] # (optional) MaxPriorityFeePerGas is the maximum miner tip per gas offered, in wei.
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
    logsBloom*: FixedBytes[256]     # the bloom filter for the logs of the block. null when its pending block.
    transactionsRoot*: Hash256      # the root of the transaction trie of the block.
    stateRoot*: Hash256             # the root of the final state trie of the block.
    receiptsRoot*: Hash256          # the root of the receipts trie of the block.
    miner*: EthAddress              # the address of the beneficiary to whom the mining rewards were given.
    difficulty*: HexQuantityStr     # integer of the difficulty for this block.
    totalDifficulty*: HexQuantityStr# integer of the total difficulty of the chain until this block.
    extraData*: HexDataStr          # the "extra data" field of this block.
    mixHash*: Hash256
    size*: HexQuantityStr           # integer the size of this block in bytes.
    gasLimit*: HexQuantityStr       # the maximum gas allowed in this block.
    gasUsed*: HexQuantityStr        # the total used gas by all transactions in this block.
    timestamp*: HexQuantityStr      # the unix timestamp for when the block was collated.
    baseFeePerGas*: Option[HexQuantityStr]
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
    removed*: bool                        # true when the log was removed, due to a chain reorganization. false if its a valid log.
    logIndex*: Option[HexQuantityStr]                # integer of the log index position in the block. null when its pending log.
    transactionIndex*: Option[HexQuantityStr]        # integer of the transactions index position log was created from. null when its pending log.
    transactionHash*: Option[Hash256]     # hash of the transactions this log was created from. null when its pending log.
    blockHash*: Option[Hash256]           # hash of the block where this log was in. null when its pending. null when its pending log.
    blockNumber*: Option[HexQuantityStr]  # the block number where this log was in. null when its pending. null when its pending log.
    address*: EthAddress                  # address from which this log originated.
    data*: seq[byte]                      # contains one or more 32 Bytes non-indexed arguments of the log.
    topics*: seq[Hash256]                 # array of 0 to 4 32 Bytes DATA of indexed log arguments.
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
    logs*: seq[FilterLog]                 # list of log objects which this transaction generated.
    logsBloom*: FixedBytes[256]           # bloom filter for light clients to quickly retrieve related logs.
    `type`*: HexQuantityStr
    root*: Option[Hash256]                # post-transaction stateroot (pre Byzantium).
    status*: Option[HexQuantityStr]       # 1 = success, 0 = failure.
    effectiveGasPrice*: HexQuantityStr    # The actual value per gas deducted from the senders account.
                                          # Before EIP-1559, this is equal to the transaction's gas price.
                                          # After, it is equal to baseFeePerGas + min(maxFeePerGas - baseFeePerGas, maxPriorityFeePerGas).

  FilterOptions* = object
    # Parameter from user
    fromBlock*: Option[string]          # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    toBlock*: Option[string]            # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    address*: seq[EthAddress]           # (optional) contract address or a list of addresses from which logs should originate.
    topics*: seq[Option[seq[Hash256]]]  # (optional) list of DATA topics. Topics are order-dependent. Each topic can also be a list of DATA with "or" options.
    blockHash*: Option[Hash256]         # (optional) hash of the block. If its present, fromBlock and toBlock, should be none. Introduced in EIP234

proc fromJson*(n: JsonNode, argName: string, result: var FilterOptions)
    {.gcsafe, raises: [KeyError,ValueError].} =
  proc getOptionString(argName: string): Option[string]
      {.gcsafe, raises: [KeyError,ValueError].} =
    let s = n.getOrDefault(argName)
    if s == nil:
      return none[string]()
    elif s.kind == JNull:
      return none[string]()
    else:
      s.kind.expect(JString, argName)
      return some[string](s.getStr())

  proc getAddress(): seq[EthAddress] {.gcsafe, raises: [ValueError].} =
    ## Address can by provided in two formats:
    ## 1. {"address": "hexAddress"}
    ## 2. {"address": ["hexAddress1", "hexAddress2" ...]}
    ## So either as sigle string or array of strings

    let addressNode = n.getOrDefault("address")
    if addressNode.isNil:
      return @[]
    else:
      case addressNode.kind
      of JString:
        var addrs: EthAddress
        fromJson(addressNode, "address", addrs)
        return @[addrs]
      of JArray:
        var addresses = newSeq[EthAddress]()
        for i, e in addressNode.elems:
          if e.kind == JString and e.str.isValidEthAddress:
            var address: EthAddress
            hexToByteArray(e.getStr(), address)
            addresses.add(address)
          else:
            let msg = "Address at index " & $i & "is not a valid Ethereum address"
            raise newException(ValueError, msg)
        return addresses
      else:
        raise newException(ValueError, "Parameter 'address` should be either string or of array of strings")

  proc getTopics(): seq[Option[seq[Hash256]]] {.gcsafe, raises: [ValueError].} =
    ## Topics can be provided in many forms:
    ## [] "anything"
    ## [A] "A in first position (and anything after)"
    ## [null, B] "anything in first position AND B in second position (and anything after)"
    ## [A, B] "A in first position AND B in second position (and anything after)"
    ## [[A, B], [A, B]] "(A OR B) in first position AND (A OR B) in second position (and anything after)"
    ##
    ## In this custom deserialized JNull is desarializing to None subtopic seq.
    ## alternative would be to deserialize to empty seq, it would simplify some
    ## filters code but would be less explicit

    let topicsNode  = n.getOrDefault("topics")
    if topicsNode.isNil:
      return @[]
    else:
      topicsNode.kind.expect(JArray, "topics")
      var filterArr = newSeq[Option[seq[Hash256]]]()
      for i, e in topicsNode.elems:
        case e.kind
        of JNull:
          # catch all match
          filterArr.add(none[seq[Hash256]]())
        of JString:
          let hexstring = e.getStr()
          # specific topic match
          if hexstring.isValidHash256:
            var hash: Hash256
            hexToByteArray(hexstring, hash.data)
            filterArr.add(some(@[hash]))
          else:
            let msg = "Invalid topic at pos: " & $i & ". Expected 32byte hex string"
            raise newException(ValueError, msg)
        of JArray:
          if len(e.elems) == 0:
            filterArr.add(none[seq[Hash256]]())
          else:
            var orFilters = newSeq[Hash256]()
            for j, orTopic in e.elems:
              if orTopic.kind == JString and orTopic.str.isValidHash256:
                var hash: Hash256
                hexToByteArray(orTopic.getStr(), hash.data)
                orFilters.add(hash)
              else:
                let msg = "Invlid topic at pos: " & $i & ", sub pos: " & $j & ". Expected 32byte hex string"
                raise newException(ValueError, msg)
            filterArr.add(some(orFilters))
        else:
          let msg = "Invalid arg at pos: " & $i & ". Expected (null, string, array)"
          raise newException(ValueError, msg)
      return filterArr

  proc getBlockHash(): Option[Hash256] {.gcsafe, raises: [KeyError,ValueError].} =
    let s = getOptionString("blockHash")
    if s.isNone():
      return none[Hash256]()
    else:
      let strHash = s.unsafeGet()
      if strHash.isValidHash256:
        var hash: Hash256
        hexToByteArray(strHash, hash.data)
        return some(hash)
      else:
        let msg = "Invalid 'blockHash'. Expected 32byte hex string"
        raise newException(ValueError, msg)

  n.kind.expect(JObject, argName)

  let blockHash = getBlockHash()
  # TODO: Tags should deserialize to some kind of Enum, to avoid using raw strings
  # in other layers. But this should be done on all endpoint to keep them constistent
  let fromBlock = getOptionString("fromBlock")
  let toBlock = getOptionString("toBlock")

  if blockHash.isSome():
    if fromBlock.isSome() or toBlock.isSome():
       raise newException(ValueError, "fromBlock and toBlock are not allowed if blockHash is present")

  result.fromBlock = fromBlock
  result.toBlock = toBlock
  result.address = getAddress()
  result.topics = getTopics()
  result.blockHash = blockHash
