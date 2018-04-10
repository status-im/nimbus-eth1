# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, ttmath,
  logging, constants, errors, validation, utils / hexadecimal, vm / base, db / db_chain

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
    networkId*: string
    vmsByRange*: seq[tuple[blockNumber: Int256, vm: VM]] # TODO
    importBlock*: bool
    validateBlock*: bool
    db*: BaseChainDB
    fundedAddress*: string
    fundedAddressInitialBalance*: int
    fundedAddressPrivateKey*: string

  GenesisParams* = ref object
    blockNumber*: Int256
    difficulty*: Int256
    gasLimit*: Int256
    parentHash*: string
    coinbase*: string
    nonce*: string
    mixHash*: string
    extraData*: string
    timestamp*: EthTime
    stateRoot*: string

  FundedAddress* = ref object
    balance*: Int256
    nonce*: int
    code*: string


proc configureChain*(name: string, blockNumber: Int256, vm: VM, importBlock: bool = true, validateBlock: bool = true): Chain =
  new(result)
  result.vmsByRange = @[(blockNumber: blockNumber, vm: vm)]
  result.importBlock = importBlock
  result.validateBlock = validateBlock

proc fromGenesis*(
    chain: Chain,
    chainDB: BaseChainDB,
    genesisParams: GenesisParams,
    genesisState: Table[string, FundedAddress]): Chain =
  ## Initialize the Chain from a genesis state
  var stateDB = chaindb.getStateDB(BLANK_ROOT_HASH)
  # TODO
  # for account, accountData in genesisState:
  #   stateDB.setBalance(account, accountData.balance)
  #   stateDB.setNonce(account, accountData.nonce)
  #   stateDB.setCode(account, accountData.code)

  new(result)
  result.db = chainDB
  result.header = BlockHeader()
  result.logger = logging.getLogger("evm.chain.chain.Chain")
  result.importBlock = chain.importBlock
  result.validateBlock = chain.validateBlock
  result.vmsByRange = chain.vmsByRange
  # TODO
  # chainDB.persistBlockToDB(result.getBlock)
