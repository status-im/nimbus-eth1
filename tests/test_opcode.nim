# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, tables, parseutils,
  eth_trie/[types, memdb], eth_common/eth_types,
  ../nimbus/[constants, vm_types, logging],
  ../nimbus/vm/interpreter,
  ../nimbus/utils/header,
  ../nimbus/db/[db_chain, state_db, backends/memory_backend],
  ./test_helpers

from eth_common import GasInt

proc testCode(code: string, initialGas: GasInt, blockNum: UInt256): BaseComputation =
  let header = BlockHeader(blockNumber: blockNum)
  var memDb = newMemDB()
  var vm = newNimbusVM(header, newBaseChainDB(trieDB memDb))
    # coinbase: "",
    # difficulty: fixture{"env"}{"currentDifficulty"}.getHexadecimalInt.u256,
    # blockNumber: fixture{"env"}{"currentNumber"}.getHexadecimalInt.u256,
    # gasLimit: fixture{"env"}{"currentGasLimit"}.getHexadecimalInt.u256,
    # timestamp: fixture{"env"}{"currentTimestamp"}.getHexadecimalInt)

  let message = newMessage(
    to=ZERO_ADDRESS, #fixture{"exec"}{"address"}.getStr,
    sender=ZERO_ADDRESS, #fixture{"exec"}{"caller"}.getStr,
    value=0.u256,
    data = @[],
    code=code,
    gas=initial_gas,
    gasPrice=1) # What is this used for?
    # gasPrice=fixture{"exec"}{"gasPrice"}.getHexadecimalInt.u256,
    #options=newMessageOptions(origin=fixture{"exec"}{"origin"}.getStr))

  #echo fixture{"exec"}
  var c = newCodeStreamFromUnescaped(code)
  if DEBUG:
    c.displayDecompiled()

  var computation = newBaseComputation(vm.state, message)
  computation.opcodes = OpLogic # TODO remove this need
  computation.precompiles = initTable[string, Opcode]()

  computation = computation.applyComputation(vm.state, message)
  result = computation

suite "opcodes":
  test "add":
    var c = testCode(
      "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff01",
      100_000,
      0.u256
      )
    check(c.gasMeter.gasRemaining == 99_991)
    check(c.stack.peek == "115792089237316195423570985008687907853269984665640564039457584007913129639934".u256)
#     let address = Address::from_str("0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6").unwrap();
#   let code = "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff01600055".from_hex().unwrap();

#   let mut params = ActionParams::default();
#   params.address = address.clone();
#   params.gas = U256::from(100_000);
#   params.code = Some(Arc::new(code));
#   let mut ext = FakeExt::new();

#   let gas_left = {
#     let mut vm = factory.create(params.gas);
#     test_finalize(vm.exec(params, &mut ext)).unwrap()
#   };

#   assert_eq!(gas_left, U256::from(79_988));
#   assert_store(&ext, 0, "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe");
# }

  test "Frontier VM computation - pre-EIP150 gas cost properly applied":
    block: # Using Balance (0x31)
      var c = testCode(
        "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff31",
        100_000,
        0.u256
        )
      check: c.gasMeter.gasRemaining == 100000 - 3 - 20 # Starting gas - push32 (verylow) - balance

    block: # Using SLOAD (0x54)
      var c = testCode(
        "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff54",
        100_000,
        0.u256
        )
      check: c.gasMeter.gasRemaining == 100000 - 3 - 50 # Starting gas - push32 (verylow) - SLOAD


  test "Tangerine VM computation - post-EIP150 gas cost properly applied":
    block: # Using Balance (0x31)
      var c = testCode(
        "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff31",
        100_000,
        2_463_000.u256 # Tangerine block
        )
      check: c.gasMeter.gasRemaining == 100000 - 3 - 400 # Starting gas - push32 (verylow) - balance

    block: # Using SLOAD (0x54)
      var c = testCode(
        "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff54",
        100_000,
        2_463_000.u256
        )
      check: c.gasMeter.gasRemaining == 100000 - 3 - 200 # Starting gas - push32 (verylow) - SLOAD
