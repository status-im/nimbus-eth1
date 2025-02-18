# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[tables, sets],
  chronos,
  chronicles,
  stint,
  results,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses, headers],
  ../network/history/history_network,
  ../network/state/[state_endpoints, state_network]

from eth/common/eth_types_rlp import rlpHash

export evmc, addresses, stint, headers, state_network

{.push raises: [].}

logScope:
  topics = "portal_evm"

type PortalEvmState* = ref object
  accounts: Table[Address, Account]
  code: Table[Address, seq[byte]]
  storage: Table[Address, Table[UInt256, (UInt256, UInt256)]]
    # maps address -> slot key -> (original slot value, updated slot value)
  created: HashSet[Address]
  selfDestructs: HashSet[Address]
  transientStorage: Table[Address, Table[UInt256, UInt256]]
  stateNetwork: Opt[StateNetwork] # when none state network lookups are disabled
  stateRoot: Opt[Hash32]
  fetchedAccounts: HashSet[Address]
  fetchedCode: HashSet[Address]
  fetchedStorage: Table[Address, HashSet[UInt256]]
  historyNetwork: Opt[HistoryNetwork] # when none history network lookups are disabled
  blockHashes: Table[uint64, Hash32]

func init*(
    T: type PortalEvmState,
    stateRoot = Opt.none(Hash32),
    sn = Opt.none(StateNetwork),
    hn = Opt.none(HistoryNetwork),
): PortalEvmState =
  if sn.isSome():
    # stateRoot is required if state network lookups are enabled
    doAssert(stateRoot.isSome())
  PortalEvmState(stateRoot: stateRoot, stateNetwork: sn, historyNetwork: hn)

template toEvmc*(state: PortalEvmState): evmc_host_context =
  evmc_host_context(state.addr)

template fromEvmc(state: evmc_host_context): PortalEvmState =
  cast[ptr PortalEvmState](context)[]

proc fetchAccountIfRequired(state: PortalEvmState, address: Address) =
  let sn = state.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if address in state.fetchedAccounts:
    return # already fetched account

  try:
    let account = waitFor(sn.getAccount(state.stateRoot.get(), address)).valueOr:
      raiseAssert("account lookup failed") # how should we handle this?
    state.accounts[address] = account
    state.fetchedAccounts.incl(address)
  except CancelledError:
    trace "stateNetwork.getAccount canceled"
    raiseAssert("account lookup failed") # how should we handle this?

proc fetchCodeIfRequired(state: PortalEvmState, address: Address) =
  let sn = state.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if address in state.fetchedCode:
    return # already fetched code

  try:
    let code = waitFor(sn.getCodeByStateRoot(state.stateRoot.get(), address)).valueOr:
      raiseAssert("code lookup failed") # how should we handle this?
    state.code[address] = code.asSeq()
    state.fetchedCode.incl(address)
  except CancelledError:
    trace "stateNetwork.getCodeByStateRoot canceled"
    raiseAssert("code lookup failed") # how should we handle this?

proc fetchStorageIfRequired(state: PortalEvmState, address: Address, slotKey: UInt256) =
  let sn = state.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if slotKey in state.fetchedStorage.getOrDefault(address):
    return # already fetched storage

  try:
    let slotValue = waitFor(
      sn.getStorageAtByStateRoot(state.stateRoot.get(), address, slotKey)
    ).valueOr:
      raiseAssert("storage lookup failed") # how should we handle this?

    state.storage.withValue(address, value):
      value[][slotKey] = (slotValue, slotValue)
    do:
      state.storage[address] = {slotKey: (slotValue, slotValue)}.toTable

    state.fetchedStorage.withValue(address, value):
      value[].incl(slotKey)
    do:
      state.fetchedStorage[address] = toHashSet([slotKey])
  except CancelledError:
    trace "stateNetwork.getStorageAtByStateRoot canceled"
    raiseAssert("storage lookup failed") # how should we handle this?

proc fetchBlockHashIfRequired(state: PortalEvmState, number: uint64) =
  let hn = state.historyNetwork.valueOr:
    return # history lookups over portal network are disabled

  if state.blockHashes.contains(number):
    return # already fetched block hash

  try:
    let header = waitFor(hn.getVerifiedBlockHeader(number)).valueOr:
      raiseAssert("block header lookup failed") # how should we handle this?
    state.blockHashes[number] = header.rlpHash()
  except CancelledError:
    trace "historyNetwork.getVerifiedBlockHeader canceled"
    raiseAssert("block header lookup failed") # how should we handle this?

proc accountExists*(state: PortalEvmState, address: Address): bool =
  state.fetchAccountIfRequired(address)
  state.accounts.contains(address)

proc getBalance*(state: PortalEvmState, address: Address): UInt256 =
  state.fetchAccountIfRequired(address)
  state.accounts.getOrDefault(address).balance

proc setBalance*(state: PortalEvmState, address: Address, value: UInt256) =
  state.fetchAccountIfRequired(address)

  state.accounts.withValue(address, acc):
    acc[].balance = value
  do:
    var account = EMPTY_ACCOUNT
    account.balance = value
    state.accounts[address] = account

proc getOriginalStorage*(
    state: PortalEvmState, address: Address, slotKey: UInt256
): UInt256 =
  state.fetchStorageIfRequired(address, slotKey)
  state.storage.getOrDefault(address).getOrDefault(slotKey)[0]

proc getCurrentStorage*(
    state: PortalEvmState, address: Address, slotKey: UInt256
): UInt256 =
  state.fetchStorageIfRequired(address, slotKey)
  state.storage.getOrDefault(address).getOrDefault(slotKey)[1]

proc setStorage*(state: PortalEvmState, address: Address, slotKey, slotValue: UInt256) =
  state.storage.withValue(address, value):
    value[][slotKey] = (value[].getOrDefault(slotKey)[0], slotValue)
  do:
    state.storage[address] = {slotKey: (0.u256, slotValue)}.toTable

proc getCode*(state: PortalEvmState, address: Address): seq[byte] =
  state.fetchCodeIfRequired(address)
  state.code.getOrDefault(address)

proc setCode*(state: PortalEvmState, address: Address, code: seq[byte]) =
  state.code[address] = code

proc getCodeSize*(state: PortalEvmState, address: Address): int =
  state.getCode(address).len()

proc getCodeHash*(state: PortalEvmState, address: Address): Hash32 =
  state.getCode(address).keccak256()

proc copyCode*(
    state: PortalEvmState,
    address: Address,
    codeOffset: int,
    buffer: var openArray[byte],
): int =
  let code = state.getCode(address)
  var i = 0
  while (i + codeOffset) < code.len() and i < buffer.len():
    buffer[i] = code[i + codeOffset]
    inc i
  i

proc accessAccount*(state: PortalEvmState, address: Address): bool =
  let warm = state.fetchedAccounts.contains(address)
  state.fetchAccountIfRequired(address)
  warm

proc accessStorage*(state: PortalEvmState, address: Address, slotKey: UInt256): bool =
  let warm = state.fetchedStorage.getOrDefault(address).contains(slotKey)
  state.fetchStorageIfRequired(address, slotKey)
  warm

proc getTransientStorage*(
    state: PortalEvmState, address: Address, slotKey: UInt256
): UInt256 =
  state.transientStorage.getOrDefault(address).getOrDefault(slotKey)

proc setTransientStorage*(
    state: PortalEvmState, address: Address, slotKey, slotValue: UInt256
) =
  state.transientStorage.withValue(address, value):
    value[][slotKey] = slotValue
  do:
    state.transientStorage[address] = {slotKey: slotValue}.toTable

proc isCreated*(state: PortalEvmState, address: Address): bool =
  state.created.contains(address)

proc addCreated*(state: PortalEvmState, address: Address) =
  state.created.incl(address)

proc isSelfDestructed*(state: PortalEvmState, address: Address): bool =
  state.selfDestructs.contains(address)

proc selfDestruct*(state: PortalEvmState, address: Address) =
  state.selfDestructs.incl(address)

proc getBlockHash*(state: PortalEvmState, number: uint64): Opt[Hash32] =
  state.fetchBlockHashIfRequired(number)
  if state.blockHashes.contains(number):
    Opt.some(state.blockHashes.getOrDefault(number))
  else:
    Opt.none(Hash32)
