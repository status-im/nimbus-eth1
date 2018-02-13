import
  os, macros, json, strformat, strutils, ttmath, utils / [hexadecimal, address], chain, vm_state, constants, db / [db_chain, state_db], vm / forks / frontier / vm

# TODO 
# This block is a child of the genesis defined in the chain fixture above and contains a single tx
# that transfers 10 wei from 0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b to
# 0x095e7baea6a6c7c4c2dfeb977efac326af552d87.
# var validBlockRlp = decodeHex(
#     "0xf90260f901f9a07285abd5b24742f184ad676e31f6054663b3529bc35ea2fcad8a3e0f642a46f7a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347948888f1f195afa192cfee860698584c030f4c9db1a0964e6c9995e7e3757e934391b4f16b50c20409ee4eb9abd4c4617cb805449b9aa053d5b71a8fbb9590de82d69dfa4ac31923b0c8afce0d30d0d8d1e931f25030dca0bc37d79753ad738a6dac4921e57392f145d8887476de3f783dfa7edae9283e52b90100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008302000001832fefd8825208845754132380a0194605bacef646779359318c7b5899559a5bf4074bbe2cfb7e1b83b1504182dd88e0205813b22e5a9cf861f85f800a82c35094095e7baea6a6c7c4c2dfeb977efac326af552d870a801ba0f3266921c93d600c43f6fa4724b7abae079b35b9e95df592f95f9f3445e94c88a012f977552ebdb7a492cf35f3106df16ccb4576ebad4113056ee1f52cbe4978c1c0")  # noqa: E501
# 
# type
#   PrivateKey = object # TODO
#     publicKey*: cstring
# 
# proc testChain*: Chain =
#  # Return a Chain object containing just the genesis block.
#  #
#  # This Chain does not perform any validation when importing new blocks.
#   #
#   # The Chain's state includes one funded account and a private key for it, which can be found in
#   # the funded_address and private_keys variables in the chain itself.
#   # Disable block validation so that we don't need to construct finalized blocks.
#  
#   var klass = configureChain(
#     "TestChainWithoutBlockValidation",
#     constants.GENESIS_BLOCK_NUMBER,
#     FrontierVM,
#     importBlock=false,
#     validateBlock=false)
# 
#   var privateKey = PrivateKey(publicKey: cstring"0x45a915e4d060149eb4365960e6a7a45f334393093061116b197e3240065ff2d8") # TODO
#   var fundedAddress = privateKey.publicKey.toCanonicalAddress()
#   var initialBalance = 100_000_000
#   var genesisParams = GenesisParams(
#     blockNumber: constants.GENESIS_BLOCK_NUMBER,
#     difficulty: constants.GENESIS_DIFFICULTY,
#     gasLimit: constants.GENESIS_GAS_LIMIT,
#     parentHash: constants.GENESIS_PARENT_HASH,
#     coinbase: constants.GENESIS_COINBASE,
#     nonce: constants.GENESIS_NONCE,
#     mixHash: constants.GENESIS_MIX_HASH,
#     extraData: constants.GENESIS_EXTRA_DATA,
#     timestamp: 1501851927,
#     stateRoot: decodeHex("0x9d354f9b5ba851a35eced279ef377111387197581429cfcc7f744ef89a30b5d4"))
# 
#   var genesisState = GenesisState(
#     fundedAddress: FundedAddress(
#       balance: initialBalance,
#       nonce: 0,
#       code: cstring""))
# 
#   result = klass.fromGenesis(newBaseChainDB(getDbBackend()), genesisParams, genesisState)
#   result.fundedAddress = fundedAddress
#   result.fundedAddressInitialBalance = initialBalance
#   result.fundedAddressPrivateKey = privateKey
# 
proc generateTest(filename: string, handler: NimNode): NimNode =
  echo filename
  result = quote:
    test `filename`:
      `handler`(parseJSON(readFile(`filename`)))

macro jsonTest*(s: static[string], handler: untyped): untyped =
  result = nnkStmtList.newTree()
  for filename in walkDir(&"tests/{s}", relative=true):
    result.add(generateTest(filename.path, handler))

proc setupStateDB*(desiredState: JsonNode, stateDB: var AccountStateDB) =
  for account, accountData in desiredState:
    for slot, value in accountData{"storage"}:
      stateDB.setStorage(account, slot.parseInt.i256, value.getInt.i256)

    let nonce = accountData{"nonce"}.getInt.i256
    let code = accountData{"code"}.getStr
    let balance = accountData{"balance"}.getInt.i256

    stateDB.setNonce(account, nonce)
    stateDB.setCode(account, code)
    stateDB.setBalance(account, balance)
