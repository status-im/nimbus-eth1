# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, ttmath,
  ./logging, ./constants, ./errors, ./validation, ./utils/hexadecimal, ./vm/base, ./db/db_chain,
  ./utils/header

type
  Chain* = ref object
    ## An Chain is a combination of one or more VM classes.  Each VM is associated
    ## with a range of blocks.  The Chain class acts as a wrapper around these other
    ## VM classes, delegating operations to the appropriate VM depending on the
    ## current block number.
    header*: BlockHeader
    logger*: Logger
    networkId*: string
    vmsByRange*: seq[tuple[blockNumber: UInt256, vmk: VMkind]] # TODO: VM should actually be a runtime typedesc(VM)
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


proc configureChain*(name: string, blockNumber: UInt256, vmk: VMKind, importBlock: bool = true, validateBlock: bool = true): Chain =
  new(result)
  result.vmsByRange = @[(blockNumber: blockNumber, vmk: vmk)]
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

proc getVMClassForBlockNumber*(chain: Chain, blockNumber: UInt256): VMKind =
  ## Returns the VM class for the given block number
  # TODO should the return value be a typedesc?

  # TODO: validate_block_number
  for idx in countdown(chain.vmsByRange.high, chain.vmsByRange.low):
    let (n, vmk) = chain.vmsByRange[idx]
    if blockNumber > n:
      return vmk

  raise newException(ValueError, "VM not found for block #" & $blockNumber) # TODO: VMNotFound exception

proc getVM*(chain: Chain, header: BlockHeader = nil): VM =
  ## Returns the VM instance for the given block number

  if header.isNil:
    let header = chain.header # shadowing input param


  let vm_class = chain.getVMClassForBlockNumber(header.blockNumber)

  # case vm_class:
  # of vmkFrontier: result =
