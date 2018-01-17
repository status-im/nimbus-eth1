import
  tables,
  logging, constants, errors, validation, utils / [hexadecimal]

type
  BlockHeader* = ref object
    # Placeholder TODO

  Chain* = ref object
    ## An Chain is a combination of one or more VM classes.  Each VM is associated
    ## with a range of blocks.  The Chain class acts as a wrapper around these other
    ## VM classes, delegating operations to the appropriate VM depending on the
    ## current block number.
    header*: BlockHeader
    logger*: Logger
    networkId*: cstring
    vmsByRange*: seq[tuple[blockNumber: Int256, vm: VM]] # TODO
    importBlock*: bool
    validateBlock*: bool
    db*: BaseChainDB

  GenesisParams* = ref object
    blockNumber*: Int256
    difficulty*: Int256
    gasLimit*: Int256
    parentHash*: cstring
    coinbase*: cstring
    nonce: cstring
    mixHash: cstring
    extraData: cstring
    timestamp: int,
    stateRoot: cstring

  FundedAddress* = ref object
    balance*: Int256
    nonce*: int
    code*: cstring


proc configureChain*(name: string, blockNumber: Int256, vm: VM, importBlock: bool = true, validateBlock: bool = true): Chain =
  new(result)
  result.vmsByRange = @[(blockNumber: blockNumber, vm: vm)]

proc fromGenesis*(
    chain: Chain,
    chainDB: BaseChainDB,
    genesisParams: GenesisParams,
    genesisState: Table[string, FundedAddress]): Chain =
  ## Initialize the Chain from a genesis state
  var stateDB = chaindb.getStateDB(BLANK_ROOT_HASH)
  for account, accountData in genesisState:
    stateDB.setBalance(account, accountData.balance)
    stateDB.setNonce(account, accountData.nonce)
    stateDB.setCode(account, accountData.code)
  
  new(result)
  result.db = chainDB
  result.header = BlockHeader()
  result.logger = logging.getLogger("evm.chain.chain.Chain")
  chainDB.persistBlockToDB(result.getBlock())
