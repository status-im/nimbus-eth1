# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import unittest, strformat, tables, constants, chain, ttmath, vm / forks / frontier / vm, utils / [header, address], db / db_chain, db / backends / memory_backend

proc chainWithoutBlockValidation: Chain =
  result = configureChain("TestChain", GENESIS_BLOCK_NUMBER, newFrontierVM(Header(), newBaseChainDB(newMemoryDB())), false, false)
  let privateKey = "0x45a915e4d060149eb4365960e6a7a45f334393093061116b197e3240065ff2d8" # TODO privateKey(decodeHex("0x45a915e4d060149eb4365960e6a7a45f334393093061116b197e3240065ff2d8"))
  let fundedAddr = privateKey # privateKey.publicKey.toCanonicalAddress
  let initialBalance = 100_000_000
  let genesisParams = GenesisParams(
    blockNumber: GENESIS_BLOCK_NUMBER,
    difficulty: GENESIS_DIFFICULTY,
    gasLimit: GENESIS_GAS_LIMIT,
    parentHash: GENESIS_PARENT_HASH,
    coinbase: GENESIS_COINBASE,
    nonce: GENESIS_NONCE,
    mixHash: GENESIS_MIX_HASH,
    extraData: GENESIS_EXTRA_DATA,
    timestamp: 1501851927,
    stateRoot: "0x9d354f9b5ba851a35eced279ef377111387197581429cfcc7f744ef89a30b5d4") #.decodeHex)
  let genesisState = {"fundedAddr": FundedAddress(balance: initialBalance.int256, nonce: 0, code: "")}.toTable()
  result = fromGenesis(
    result,
    newBaseChainDB(newMemoryDB()),
    genesisParams,
    genesisState)
  result.fundedAddress = fundedAddr
  result.fundedAddressInitialBalance = initialBalance
  result.fundedAddressPrivateKey = privateKey

