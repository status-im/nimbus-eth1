import
  testutils/fuzzing, ../../nimbus/db/core_db,
  ./tree_from_witness, ./witness_types

# please read instruction in status-im/nim-testutils/fuzzing/readme.md
# or status-im/nim-testutils/fuzzing/fuzzing_on_windows.md
# if you want to run fuzz test

test:
  var db = newCoreDbRef(LegacyDbMemory)
  try:
    var tb = initTreeBuilder(payload, db, {wfEIP170})
    let root = tb.buildTree()
  except ParsingError, ContractCodeError:
    debugEcho "Error detected ", getCurrentExceptionMsg()
