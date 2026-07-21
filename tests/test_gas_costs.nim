# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[monotimes, times, strformat, cmdline],
  unittest2,
  eth/common/eth_types,
  ../execution_chain/evm/interpreter/gas_costs,
  ../execution_chain/evm/interpreter/op_codes,
  ../execution_chain/common/evmforks

const
  MemCases = [
    (0, 0, 0),
    (0, 0, 1),
    (0, 0, 32),
    (0, 0, 33),
    (64, 0, 32),
    (64, 32, 32),
    (64, 100, 32),
    (64, 100, 0),
    (1024, 4096, 32),
    (1024, 128, 256),
    (32, 0, 0),
    (0, 1_000_000, 1_000_000),
  ]

suite "Direct gas cost functions match table handlers":
  test "memory expansion ops":
    for fork in FkFrontier..high(EVMFork):
      let costs = forkToSchedule(fork)
      for (mem, offset, len) in MemCases:
        check costs[Mload].m_handler(mem, offset, len) ==
          gasLoadStore(mem, offset, len)
        check costs[Mstore].m_handler(mem, offset, len) ==
          gasLoadStore(mem, offset, len)
        check costs[Mstore8].m_handler(mem, offset, len) ==
          gasLoadStore(mem, offset, len)
        check costs[Mcopy].m_handler(mem, offset, len) ==
          gasCopy(mem, offset, len)
        check costs[CallDataCopy].m_handler(mem, offset, len) ==
          gasCopy(mem, offset, len)
        check costs[CodeCopy].m_handler(mem, offset, len) ==
          gasCopy(mem, offset, len)
        check costs[ReturnDataCopy].m_handler(mem, offset, len) ==
          gasCopy(mem, offset, len)
        check costs[Op.Sha3].m_handler(mem, offset, len) ==
          gasSha3(mem, offset, len)
        check costs[Log0].m_handler(mem, offset, len) ==
          gasLog(0, mem, offset, len)
        check costs[Log1].m_handler(mem, offset, len) ==
          gasLog(1, mem, offset, len)
        check costs[Log2].m_handler(mem, offset, len) ==
          gasLog(2, mem, offset, len)
        check costs[Log3].m_handler(mem, offset, len) ==
          gasLog(3, mem, offset, len)
        check costs[Log4].m_handler(mem, offset, len) ==
          gasLog(4, mem, offset, len)
        check costs[Return].m_handler(mem, offset, len) ==
          gasMemoryExpansion(mem, offset, len)
        check costs[Revert].m_handler(mem, offset, len) ==
          gasMemoryExpansion(mem, offset, len)
        check costs[Create2].m_handler(0, 0, len) ==
          gasCreate2(len)

  test "exp":
    for fork in FkFrontier..high(EVMFork):
      let costs = forkToSchedule(fork)
      for value in [0.u256, 1.u256, 255.u256, 256.u256, 65536.u256,
                    high(UInt256)]:
        check costs[Exp].d_handler(value) == gasExp(value, fork)

  test "selfdestruct":
    for fork in FkTangerine..high(EVMFork):
      let costs = forkToSchedule(fork)
      for condition in [false, true]:
        if fork >= FkAmsterdam:
          check costs[SelfDestruct].sc_handler(condition) ==
            gasSelfDestructEIP8037(condition)
        else:
          check costs[SelfDestruct].sc_handler(condition) ==
            gasSelfDestruct(condition)

const Iters = 20_000_000

proc runPair(name: string, oldNs, newNs: float64) =
  echo &"{name:<28} table handler {oldNs:6.2f} ns/op   direct {newNs:6.2f} ns/op   speedup {oldNs/newNs:5.2f}x"

proc benchmark() =
  let fork = if paramCount() < 100: FkCancun else: FkFrontier
  let costs = forkToSchedule(fork)

  var positions: array[1024, int]
  for i in 0 ..< positions.len:
    positions[i] = (i * 37) and 4095

  var exponents: array[8, UInt256]
  for i in 0 ..< exponents.len:
    exponents[i] = (1.u256 shl (i * 29)) + i.u256

  var acc: uint64

  template timeIt(body: untyped): float64 =
    block:
      let start = getMonoTime()
      for i {.inject.} in 0 ..< Iters:
        body
      float64((getMonoTime() - start).inNanoseconds) / float64(Iters)

  for warmup in 0 ..< 2:
    acc += uint64 costs[Mload].m_handler(4096, positions[warmup], 32)
    acc += uint64 gasLoadStore(4096, positions[warmup], 32)

  runPair "MLOAD (GckMemExpansion)",
    timeIt(acc += uint64 costs[Mload].m_handler(4096, positions[i and 1023], 32)),
    timeIt(acc += uint64 gasLoadStore(4096, positions[i and 1023], 32))

  runPair "SHA3 (GckMemExpansion)",
    timeIt(acc += uint64 costs[Op.Sha3].m_handler(4096, positions[i and 1023], 64)),
    timeIt(acc += uint64 gasSha3(4096, positions[i and 1023], 64))

  runPair "LOG2 (GckMemExpansion)",
    timeIt(acc += uint64 costs[Log2].m_handler(4096, positions[i and 1023], 64)),
    timeIt(acc += uint64 gasLog(2, 4096, positions[i and 1023], 64))

  runPair "EXP (GckDynamic)",
    timeIt(acc += uint64 costs[Exp].d_handler(exponents[i and 7])),
    timeIt(acc += uint64 gasExp(exponents[i and 7], fork))

  runPair "SELFDESTRUCT (GckSuicide)",
    timeIt(acc += uint64 costs[SelfDestruct].sc_handler((i and 63) == 0)),
    timeIt(acc += uint64 gasSelfDestruct((i and 63) == 0))

  doAssert acc > 0

when defined(release):
  benchmark()
