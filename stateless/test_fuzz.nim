import
  testutils/fuzzing, eth/trie/db,
  ./tree_from_witness, ./witness_types

test:
  var db = newMemoryDB()
  try:
    var tb = initTreeBuilder(payload, db, {wfEIP170})
    let root = tb.buildTree()
  except ParsingError, ContractCodeError:
    debugEcho "Error detected ", getCurrentExceptionMsg()
