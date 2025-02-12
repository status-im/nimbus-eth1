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
  # stew/byteutils,
  # stew/ptrops,
  stint,
  results,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses, headers],
  # ../../execution_chain/evm/evmc_helpers,
  ../network/state/state_endpoints

export evmc, addresses, stint, headers, state_network

{.push raises: [].}

{.pragma: evmc_abi, cdecl, gcsafe, raises: [].}

logScope:
  topics = "portal_evm"

# TODO: transaction context
type PortalEvmContextRef* = ref object
  header: Header
  accounts: Table[Address, Account]
  code: Table[Address, seq[byte]]
  storage: Table[Address, Table[UInt256, (UInt256, UInt256)]]
    # maps address -> slot key -> (original slot value, updated slot value)
  transientStorage: Table[Address, Table[UInt256, UInt256]]
  stateNetwork: Opt[StateNetwork] # when none network lookups are disabled
  fetchedAccounts: HashSet[Address]
  fetchedCode: HashSet[Address]
  fetchedStorage: Table[Address, HashSet[UInt256]]

func init*(
    T: type PortalEvmContextRef, header: Header, stateNetwork = Opt.none(StateNetwork)
): PortalEvmContextRef =
  PortalEvmContextRef(header: header, stateNetwork: stateNetwork)

# TODO: implement a function to clear the transient storage after executing a transaction

template toEvmc*(context: PortalEvmContextRef): evmc_host_context =
  evmc_host_context(context.addr)

template fromEvmc(context: evmc_host_context): PortalEvmContextRef =
  cast[ptr PortalEvmContextRef](context)[]

proc fetchAccountIfRequired(context: PortalEvmContextRef, address: Address) =
  let sn = context.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if address in context.fetchedAccounts:
    return # already fetched account

  try:
    let account = waitFor(sn.getAccount(context.header.stateRoot, address)).valueOr:
      raiseAssert("account lookup failed") # how should we handle this?
    context.accounts[address] = account
    context.fetchedAccounts.incl(address)
  except CancelledError:
    trace "stateNetwork.getAccount canceled"

proc fetchCodeIfRequired(context: PortalEvmContextRef, address: Address) =
  let sn = context.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if address in context.fetchedCode:
    return # already fetched code

  try:
    let code = waitFor(sn.getCodeByStateRoot(context.header.stateRoot, address)).valueOr:
      raiseAssert("code lookup failed") # how should we handle this?
    context.code[address] = code.asSeq()
    context.fetchedCode.incl(address)
  except CancelledError:
    trace "stateNetwork.getCodeByStateRoot canceled"

proc fetchStorageIfRequired(
    context: PortalEvmContextRef, address: Address, slotKey: UInt256
) =
  let sn = context.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if slotKey in context.fetchedStorage.getOrDefault(address):
    return # already fetched storage

  try:
    let slotValue = waitFor(
      sn.getStorageAtByStateRoot(context.header.stateRoot, address, slotKey)
    ).valueOr:
      raiseAssert("storage lookup failed") # how should we handle this?

    context.storage.withValue(address, value):
      value[][slotKey] = (slotValue, slotValue)
    do:
      context.storage[address] = {slotKey: (slotValue, slotValue)}.toTable

    context.fetchedStorage.withValue(address, value):
      value[].incl(slotKey)
    do:
      context.fetchedStorage[address] = toHashSet([slotKey])
  except CancelledError:
    trace "stateNetwork.getStorageAtByStateRoot canceled"

proc accountExists*(context: PortalEvmContextRef, address: Address): bool =
  context.fetchAccountIfRequired(address)
  context.accounts.contains(address)

proc getOriginalStorage*(
    context: PortalEvmContextRef, address: Address, slotKey: UInt256
): UInt256 =
  context.fetchStorageIfRequired(address, slotKey)
  context.storage.getOrDefault(address).getOrDefault(slotKey)[0]

proc getCurrentStorage*(
    context: PortalEvmContextRef, address: Address, slotKey: UInt256
): UInt256 =
  context.fetchStorageIfRequired(address, slotKey)
  context.storage.getOrDefault(address).getOrDefault(slotKey)[1]

proc setStorage*(
    context: PortalEvmContextRef, address: Address, slotKey, slotValue: UInt256
) =
  context.storage.withValue(address, value):
    value[][slotKey] = (value[].getOrDefault(slotKey)[0], slotValue)
  do:
    context.storage[address] = {slotKey: (0.u256, slotValue)}.toTable

proc getBalance*(context: PortalEvmContextRef, address: Address): UInt256 =
  context.fetchAccountIfRequired(address)
  context.accounts.getOrDefault(address).balance

proc getCode*(context: PortalEvmContextRef, address: Address): seq[byte] =
  context.fetchCodeIfRequired(address)
  context.code.getOrDefault(address)

proc getCodeSize*(context: PortalEvmContextRef, address: Address): int =
  context.getCode(address).len()

proc getCodeHash*(context: PortalEvmContextRef, address: Address): Hash32 =
  context.getCode(address).keccak256()

proc copyCode*(
    context: PortalEvmContextRef,
    address: Address,
    codeOffset: int,
    buffer: var openArray[byte],
): int =
  let code = context.getCode(address)
  var i = 0
  while (i + codeOffset) < code.len() and i < buffer.len():
    buffer[i] = code[i + codeOffset]
    inc i
  i

proc accessAccount*(context: PortalEvmContextRef, address: Address): bool =
  let warm = context.fetchedAccounts.contains(address)
  context.fetchAccountIfRequired(address)
  warm

proc accessStorage*(
    context: PortalEvmContextRef, address: Address, slotKey: UInt256
): bool =
  let warm = context.fetchedStorage.getOrDefault(address).contains(slotKey)
  context.fetchStorageIfRequired(address, slotKey)
  warm

proc getTransientStorage*(
    context: PortalEvmContextRef, address: Address, slotKey: UInt256
): UInt256 =
  context.transientStorage.getOrDefault(address).getOrDefault(slotKey)

proc setTransientStorage*(
    context: PortalEvmContextRef, address: Address, slotKey, slotValue: UInt256
) =
  context.transientStorage.withValue(address, value):
    value[][slotKey] = slotValue
  do:
    context.transientStorage[address] = {slotKey: slotValue}.toTable
