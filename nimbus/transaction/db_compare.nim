# Nimbus - Steps towards a fast and small Ethereum data store
#
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  sets, tables,
  stint, chronicles, stew/byteutils,
  eth/common/eth_types,
  ../constants,
  ./host_types, ./db_query

template toHex(hash: Hash256): string = hash.data.toHex

type
  DbSeenAccount* = ref object
    seenNonce*:       bool
    seenBalance*:     bool
    seenCodeHash*:    bool
    seenExists*:      bool
    seenStorages*:    HashSet[UInt256]
    seenAllStorages*: bool

  DbSeenAccounts* = ref Table[EthAddress, DbSeenAccount]

  DbSeenBlocks* = ref Table[BlockNumber, DbSeenAccounts]

  DbCompare = object
    ethDb: EthDB
    errorCount: int
    seen: DBSeenBlocks

var dbCompare {.threadvar.}: DbCompare
  # `dbCompare` is cross-cutting; a global is fine for these tests.
  # This is thread-local for Nim simplicity.

template dbCompareEnabled*: bool =
  dbCompare.ethDb != nil

template dbCompareErrorCount*: int =
  dbCompare.errorCount

proc dbCompareResetSeen*() =
  dbCompare.seen = nil
  if dbCompareEnabled:
    dbCompare.ethDb.ethDbShowStats()

proc dbCompareOpen*(path: string) {.raises: [IOError, OSError, Defect].} =
  # Raises `OSError` on error, good enough for this versipn.
  dbCompare.ethDb = ethDbOpen(path)
  info "DB: Verifying all EVM inputs against compressed state history database",
    file=path, size=dbCompare.ethDb.ethDbSize()

proc lookupAccount(blockNumber: BlockNumber, address: EthAddress,
                   field: string, accountResult: var DbAccount): bool =
  debug "DB COMPARE: Looking up account field",
    parentBlock=blockNumber, account=address, field
  return dbCompare.ethDb.ethDbQueryAccount(blockNumber, address, accountResult)

proc lookupStorage(blockNumber: BlockNumber, address: EthAddress,
                   slot: UInt256, slotResult: var DbSlotResult): bool =
  debug "DB COMPARE: Looking up account storage slot",
    parentBlock=blockNumber, account=address, slot=slot.toHex
  return dbCompare.ethDb.ethDbQueryStorage(blockNumber, address, slot, slotResult)

template getParentBlockNumber(blockNumber: BlockNumber): BlockNumber =
  # Uses state from previous block.
  blockNumber - 1

proc getSeenAccount(blockNumber: BlockNumber, address: EthAddress): DBSeenAccount =
  # Keep track of what fields have been read already, so that later requests
  # for the same address etc during the processing of a block are not checked.
  # Because later requests are intermediate values, not based on the parent
  # block's `stateRoot`, their values are not expected to match the DB.
  let blockNumber = getParentBlockNumber(blockNumber)
  if dbCompare.seen.isNil:
    dbCompare.seen = newTable[BlockNumber, DbSeenAccounts]()
  let seenAccountsRef = dbCompare.seen.mgetOrPut(blockNumber, nil).addr
  if seenAccountsRef[].isNil:
    seenAccountsRef[] = newTable[EthAddress, DBSeenAccount]()
  let seenAccountRef = seenAccountsRef[].mgetOrPut(address, nil).addr
  if seenAccountRef[].isNil:
    seenAccountRef[] = DBSeenAccount()
  return seenAccountRef[]

proc dbCompareFail() =
  inc dbCompare.errorCount
  if dbCompare.errorCount < 100 or dbCompare.errorCount mod 100 == 0:
    error "*** DB COMPARE: Error count", errorCount=dbCompare.errorCount
  doAssert dbCompare.errorCount < 10000

proc dbCompareNonce*(blockNumber: BlockNumber, address: EthAddress,
                     nonce: AccountNonce) =
  let seenAccount = getSeenAccount(blockNumber, address)
  if seenAccount.seenNonce:
    return
  seenAccount.seenNonce = true

  let blockNumber = getParentBlockNumber(blockNumber)
  var accountResult {.noinit.}: DbAccount
  let found = lookupAccount(blockNumber, address, "nonce", accountResult)
  if not found:
    if nonce != 0:
      error "*** DB MISMATCH: Account missing, expected nonce != 0",
        parentBlock=blockNumber, account=address, expectedNonce=nonce
      dbCompareFail()
  else:
    if nonce != accountResult.nonce:
      error "*** DB MISMATCH: Account found, nonce does not match",
        parentBlock=blockNumber, account=address, expectedNonce=nonce,
        foundNonce=accountResult.nonce
      dbCompareFail()

proc dbCompareBalance*(blockNumber: BlockNumber, address: EthAddress,
                       balance: UInt256) =
  let seenAccount = getSeenAccount(blockNumber, address)
  if seenAccount.seenBalance:
    return
  seenAccount.seenBalance = true

  let blockNumber = getParentBlockNumber(blockNumber)
  var accountResult {.noinit.}: DbAccount
  let found = lookupAccount(blockNumber, address, "balance", accountResult)
  if not found:
    if balance != 0:
      error "*** DB MISMATCH: Account missing, expected balance != 0",
        parentBlock=blockNumber, account=address, expectedBalance=balance.toHex
      dbCompareFail()
  else:
    if balance != accountResult.balance:
      error "*** DB MISMATCH: Account found, balance does not match",
        parentBlock=blockNumber, account=address, expectedBalance=balance.toHex,
        foundBalance=accountResult.balance.toHex
      dbCompareFail()

proc dbCompareCodeHash*(blockNumber: BlockNumber, address: EthAddress,
                        codeHash: Hash256) =
  let seenAccount = getSeenAccount(blockNumber, address)
  if seenAccount.seenCodeHash:
    return
  seenAccount.seenCodeHash = true

  let zeroifiedCodeHash: Hash256 =
    if codeHash == EMPTY_SHA3: ZERO_HASH256 else: codeHash

  let blockNumber = getParentBlockNumber(blockNumber)
  var accountResult {.noinit.}: DbAccount
  let found = lookupAccount(blockNumber, address, "codeHash", accountResult)
  if not found:
    if zeroifiedCodeHash != ZERO_HASH256:
      error "*** DB MISMATCH: Account missing, expected codeHash != 0",
        parentBlock=blockNumber, account=address,
        expectedCodeHash=zeroifiedCodeHash.toHex
      dbCompareFail()
  else:
    if zeroifiedCodeHash != accountResult.codeHash:
      error "*** DB MISMATCH: Account found, codeHash does not match",
        parentBlock=blockNumber, account=address,
        expectedCodeHash=zeroifiedCodeHash.toHex,
        foundCodeHash=accountResult.codeHash.toHex
      dbCompareFail()

proc dbCompareExists*(blockNumber: BlockNumber, address: EthAddress,
                      exists: bool, forkSpurious: bool) =
  let seenAccount = getSeenAccount(blockNumber, address)
  if seenAccount.seenExists:
    return
  seenAccount.seenExists = true

  let blockNumber = getParentBlockNumber(blockNumber)
  var accountResult {.noinit.}: DbAccount
  let found = lookupAccount(blockNumber, address, "exists", accountResult)
  if found != exists:
    if exists:
      error "*** DB MISMATCH: Account missing, expected exists=true",
        parentBlock=blockNumber, account=address
    else:
      error "*** DB MISMATCH: Account found, expected exists=false",
        parentBlock=blockNumber, account=address
    dbCompareFail()

proc dbCompareStorage*(blockNumber: BlockNumber, address: EthAddress,
                       slot: UInt256, value: UInt256) =
  let seenAccount = getSeenAccount(blockNumber, address)
  if seenAccount.seenAllStorages:
    return
  if seenAccount.seenStorages.containsOrIncl(slot):
    return

  let blockNumber = getParentBlockNumber(blockNumber)
  var slotResult {.noinit.}: DbSlotResult
  let found = lookupStorage(blockNumber, address, slot, slotResult)
  if not found:
    if slotResult.value != 0.u256:
      error "*** DB MISMATCH: Storage slot missing, expecting value != 0",
        parentBlock=blockNumber, account=address, slot=slot.toHex,
        expectedValue=slotResult.value.toHex
      dbCompareFail()
  else:
    if value != slotResult.value:
      error "*** DB MISMATCH: Storage slot found, value does not match",
        parentBlock=blockNumber, account=address, slot=slot.toHex,
        expectedValue=value.toHex, foundValue=slotResult.value.toHex
      dbCompareFail()

proc dbCompareClearStorage*(blockNumber: BlockNumber, address: EthAddress) =
  let seenAccount = getSeenAccount(blockNumber, address)
  seenAccount.seenAllStorages = true
  seenAccount.seenStorages.init()
  let blockNumber = getParentBlockNumber(blockNumber)
  debug "DB COMPARE: Clearing all storage slots for self-destruct",
    parentBlock=blockNumber, account=address

template getBlockNumber(host: TransactionHost): BlockNumber =
  host.vmState.blockHeader.blockNumber

proc dbCompareNonce*(host: TransactionHost,
                     address: EthAddress, nonce: AccountNonce) {.inline.} =
  host.getBlockNumber.dbCompareNonce(address, nonce)

proc dbCompareBalance*(host: TransactionHost, address: EthAddress,
                       balance: UInt256) {.inline.} =
  host.getBlockNumber.dbCompareBalance(address, balance)

proc dbCompareCodeHash*(host: TransactionHost, address: EthAddress,
                        codeHash: Hash256) {.inline.} =
  host.getBlockNumber.dbCompareCodeHash(address, codeHash)

proc dbCompareExists*(host: TransactionHost, address: EthAddress,
                      exists: bool, forkSpurious: bool) {.inline.} =
  host.getBlockNumber.dbCompareExists(address, exists, forkSpurious)

proc dbCompareStorage*(host: TransactionHost, address: EthAddress,
                       slot: UInt256, value: UInt256) {.inline.} =
  host.getBlockNumber.dbCompareStorage(address, slot, value)

proc dbCompareClearStorage*(host: TransactionHost, address: EthAddress) =
  host.getBlockNumber.dbCompareClearStorage(address)
