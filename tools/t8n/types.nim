import
  std/[tables],
  eth/common,
  ../../nimbus/[chain_config]

type
  TestFork* = enum
    Frontier
    Homestead
    EIP150
    EIP158
    Byzantium
    Constantinople
    ConstantinopleFix
    Istanbul
    FrontierToHomesteadAt5
    HomesteadToEIP150At5
    HomesteadToDaoAt5
    EIP158ToByzantiumAt5
    ByzantiumToConstantinopleAt5
    ByzantiumToConstantinopleFixAt5
    ConstantinopleFixToIstanbulAt5
    Berlin
    BerlinToLondonAt5
    London
    ArrowGlacier
    GrayGlacier
    Merged

  LogLevel* = enum
    Silent
    Error
    Warn
    Info
    Debug
    Detail

  T8NExitCode* = distinct int

  T8NError* = object of CatchableError
    exitCode*: T8NExitCode

  Ommer* = object
    delta*: uint64
    address*: EthAddress

  EnvStruct* = object
    currentCoinbase*: EthAddress
    currentDifficulty*: Option[DifficultyInt]
    currentRandom*: Option[Hash256]
    parentDifficulty*: Option[DifficultyInt]
    currentGasLimit*: GasInt
    currentNumber*: BlockNumber
    currentTimestamp*: EthTime
    parentTimestamp*: EthTime
    blockHashes*: Table[uint64, Hash256]
    ommers*: seq[Ommer]
    currentBaseFee*: Option[UInt256]
    parentUncleHash*: Hash256

  TransContext* = object
    alloc*: GenesisAlloc
    txs*: seq[Transaction]
    env*: EnvStruct

  RejectedTx* = object
    index*: int
    error*: string

  TxReceipt* = object
    txType*: TxType
    root*: Hash256
    status*: bool
    cumulativeGasUsed*: GasInt
    logsBloom*: BloomFilter
    logs*: seq[Log]
    transactionHash*: Hash256
    contractAddress*: EthAddress
    gasUsed*: GasInt
    blockHash*: Hash256
    transactionIndex*: int

  # ExecutionResult contains the execution status after running a state test, any
  # error that might have occurred and a dump of the final state if requested.
  ExecutionResult* = object
    stateRoot*: Hash256
    txRoot*: Hash256
    receiptsRoot*: Hash256
    logsHash*: Hash256
    bloom*: BloomFilter
    receipts*: seq[TxReceipt]
    rejected*: seq[RejectedTx]
    currentDifficulty*: Option[DifficultyInt]
    gasUsed*: GasInt

const
  ErrorEVM*              = 2.T8NExitCode
  ErrorConfig*           = 3.T8NExitCode
  ErrorMissingBlockhash* = 4.T8NExitCode

  ErrorJson* = 10.T8NExitCode
  ErrorIO*   = 11.T8NExitCode
  ErrorRlp*  = 12.T8NExitCode

proc newError*(code: T8NExitCode, msg: string): ref T8NError =
  (ref T8NError)(exitCode: code, msg: msg)
