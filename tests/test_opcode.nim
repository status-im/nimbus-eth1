import
  unittest, ttmath, tables, parseutils,
  ../src/[constants, types, errors, logging],
  ../src/[chain, vm_state, computation, opcode, opcode_table],
  ../src/[utils/header, utils/padding],
  ../src/vm/[gas_meter, message, code_stream, stack],
  ../src/vm/forks/frontier/vm,
  ../src/db/[db_chain, state_db, backends/memory_backend],
  test_helpers


proc testCode(code: string, gas: UInt256): BaseComputation =
  var vm = newFrontierVM(Header(), newBaseChainDB(newMemoryDB()))
  let header = Header()
    # coinbase: "",
    # difficulty: fixture{"env"}{"currentDifficulty"}.getHexadecimalInt.u256,
    # blockNumber: fixture{"env"}{"currentNumber"}.getHexadecimalInt.u256,
    # gasLimit: fixture{"env"}{"currentGasLimit"}.getHexadecimalInt.u256,
    # timestamp: fixture{"env"}{"currentTimestamp"}.getHexadecimalInt)

  let message = newMessage(
    to="", #fixture{"exec"}{"address"}.getStr,
    sender="", #fixture{"exec"}{"caller"}.getStr,
    value=0.u256,
    data = @[],
    code=code,
    gas=gas,
    gasPrice=1.u256)
    # gasPrice=fixture{"exec"}{"gasPrice"}.getHexadecimalInt.u256,
    #options=newMessageOptions(origin=fixture{"exec"}{"origin"}.getStr))

  #echo fixture{"exec"}
  var c = newCodeStreamFromUnescaped(code)
  #if DEBUG:
  c.displayDecompiled()

  var computation = newBaseComputation(vm.state, message)
  computation.accountsToDelete = initTable[string, string]()
  computation.opcodes = OPCODE_TABLE
  computation.precompiles = initTable[string, Opcode]()

  computation = computation.applyComputation(vm.state, message)
  result = computation

suite "opcodes":
  test "add":
    var c = testCode("0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff01", 100_000.u256)
    check(c.gasMeter.gasRemaining == 99_991.u256)
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
