# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  std/heapqueue,
  stint,
  stew/assign2,
  eth/common/receipts,
  ./types,
  ../db/ledger,
  ../constants

type
  Closure = object
    address: Address
    value: UInt256

func `<`(a, b: Closure): bool =
  cmpMem(a.address.data[0].addr, b.address.data[0].addr, 20) < 0

func createSelfDestructLog(beneficiary: Address, value: UInt256): Log =
  # Selfdestruct event signature (keccak256('Selfdestruct(address,uint256)'))
  const eventSig = bytes32"0x4bfaba3443c1a1836cd362418edc679fc96cae8449cbefccb6457cdf2c943083"
  result.topics = newSeq[Topic](2)
  result.address = SYSTEM_ADDRESS
  assign(result.topics[0], eventSig)
  assign(result.topics[1].data.toOpenArray(12, 31), beneficiary.data)
  assign(result.data, value.toBytesBE())

func createTransferLog(originator, beneficiary: Address, value: UInt256): Log =
  # Transfer event signature (keccak256('Transfer(address,address,uint256)'))
  const eventSig = bytes32"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  result.topics = newSeq[Topic](3)
  result.address = SYSTEM_ADDRESS
  assign(result.topics[0], eventSig)
  assign(result.topics[1].data.toOpenArray(12, 31), originator.data)
  assign(result.topics[2].data.toOpenArray(12, 31), beneficiary.data)
  assign(result.data, value.toBytesBE())

# Using `proc` as `addLogEntry()` might be `proc` in logging mode
func addLogEntry*(c: Computation, log: Log) =
  c.logEntries.add log

func emitSelfDestructLog*(c: Computation, beneficiary: Address, value: UInt256, newContract: bool) =
  if value.isZero:
    return

  if c.msg.contractAddress != beneficiary:
    # SELFDESTRUCT to other → Transfer log (LOG3)
    c.addLogEntry(createTransferLog(c.msg.contractAddress, beneficiary, value))
  elif newContract:
    # SELFDESTRUCT to self → Selfdestruct log (LOG2)
    c.addLogEntry(createSelfDestructLog(beneficiary, value))

func emitTransferLog*(c: Computation) =
  if c.msg.value.isZero:
    return

  if c.msg.sender == c.msg.contractAddress:
    return

  c.addLogEntry(createTransferLog(c.msg.sender, c.msg.contractAddress, c.msg.value))

proc emitClosureLogs*(vmState: BaseVMState, logs: var seq[Log]) =
  # Collect selfdestruct addresses with nonzero balances, sorted lexicographically
  var closures = initHeapQueue[Closure]()
  for address, value in vmState.ledger.nonZeroSelfDestructAccounts:
    closures.push(Closure(address: address, value: value))

  # Emit Selfdestruct log for each closure
  while closures.len > 0:
    let cc = closures.pop()
    logs.add(createSelfDestructLog(cc.address, cc.value))
