# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[monotimes, times],
  unittest2,
  stint,
  eth/common,
  eth/common/[keys, transaction_utils],
  ./macro_assembler,
  ../execution_chain/common/common,
  ../execution_chain/db/ledger,
  ../execution_chain/evm/types,
  ../execution_chain/evm/state,
  ../execution_chain/transaction/[call_types, call_evm]

import ../execution_chain/transaction except GasPrice

const
  CallsPerRun = 10_000
  BenchRuns = 5
  WarmupRuns = 2

  calleeAddress = address"00000000000000000000000000000000000000ca"

let
  calleeCode = evmByteCode:
    Push1 "0x00"
    Pop
    Stop

  # Loop `CallsPerRun` times over a STATICCALL to `calleeAddress`. The loop body
  # keeps everything but the call itself as cheap as possible so that the
  # measurement is dominated by the CALL gas path.
  callerCode = evmByteCode:
    Push2 "0x2710"    # counter
    JumpDest          # pc 3, loop head
    Push1 "0x00"      # retLen
    Push1 "0x00"      # retOffset
    Push1 "0x00"      # argsLen
    Push1 "0x00"      # argsOffset
    Push20 "0x00000000000000000000000000000000000000ca"
    Push2 "0x2710"    # gas forwarded to the child
    StaticCall
    Pop
    Push1 "0x01"
    Swap1
    Sub               # counter -= 1
    Dup1
    Push1 "0x03"
    JumpI             # loop while counter != 0
    Stop

static:
  doAssert CallsPerRun == 0x2710, "loop counter in callerCode must match CallsPerRun"

proc setupVM(fork: string): BaseVMState =
  let vmState = initVMEnv(fork)
  vmState.mutateLedger:
    ledger.setCode(codeAddress, callerCode)
    ledger.setBalance(codeAddress, 1_000_000.u256)
    ledger.setCode(calleeAddress, calleeCode)
  vmState

proc benchTx(chainId: ChainId): Transaction =
  let
    privateKey = PrivateKey.fromHex(
      "7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d")[]
    unsignedTx = Transaction(
      txType: TxLegacy,
      nonce: 0,
      gasPrice: 1.GasInt,
      gasLimit: 500_000_000.GasInt,
      to: Opt.some codeAddress,
      value: 0.u256,
      payload: @[],
      chainId: chainId)
  signTransaction(unsignedTx, privateKey, false)

proc runWorkload(vmState: BaseVMState): DebugCallResult =
  let tx = benchTx(vmState.com.chainId)
  testCallEvm(tx, tx.recoverSender().expect("valid signature"), vmState)

suite "EVM call gas path benchmark":
  test "STATICCALL workload runs to completion":
    let
      vmState = setupVM("Cancun")
      res = runWorkload(vmState)

    check res.error.len == 0
    # A warm STATICCALL plus the loop overhead; the exact figure is what the
    # refactored gas path must keep producing.
    echo "gas used for ", CallsPerRun, " STATICCALLs: ", res.gasUsed
    check res.gasUsed > 0

  test "throughput and allocation per CALL":
    for _ in 0 ..< WarmupRuns:
      discard runWorkload(setupVM("Cancun"))

    var
      total: Duration
      allocated: int

    for _ in 0 ..< BenchRuns:
      let vmState = setupVM("Cancun")

      GC_fullCollect()
      let occupiedBefore = getOccupiedMem()
      GC_disable()

      let start = getMonoTime()
      let res = runWorkload(vmState)
      total += getMonoTime() - start

      allocated += getOccupiedMem() - occupiedBefore
      GC_enable()
      doAssert res.error.len == 0, res.error

    let
      calls = BenchRuns * CallsPerRun
      nsPerCall = total.inNanoseconds div calls
      bytesPerCall = allocated div calls

    echo "STATICCALL: ", calls, " calls in ", total.inMilliseconds, " ms (",
      nsPerCall, " ns/call)"
    echo "GC bytes allocated per CALL: ", bytesPerCall

    check nsPerCall > 0

  test "Prague delegation path throughput":
    for _ in 0 ..< WarmupRuns:
      discard runWorkload(setupVM("Prague"))

    var total: Duration
    for _ in 0 ..< BenchRuns:
      let vmState = setupVM("Prague")
      let start = getMonoTime()
      let res = runWorkload(vmState)
      total += getMonoTime() - start
      doAssert res.error.len == 0, res.error

    let
      calls = BenchRuns * CallsPerRun
      nsPerCall = total.inNanoseconds div calls

    echo "STATICCALL (Prague): ", calls, " calls in ", total.inMilliseconds,
      " ms (", nsPerCall, " ns/call)"

    check nsPerCall > 0
