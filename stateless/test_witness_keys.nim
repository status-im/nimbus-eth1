import
  randutils, stew/byteutils, random,
  eth/[common, rlp], eth/trie/[hexary, db],
  faststreams/input_stream,
  ../stateless/[witness_from_tree, tree_from_witness]

proc runTest(keyBytes: int, valBytes: int, numPairs: int) =
  var memDB = newMemoryDB()
  var trie = initHexaryTrie(memDB)

  var
    keys = newSeq[Bytes](numPairs)
    vals = newSeq[Bytes](numPairs)

  for i in 0..<numPairs:
    keys[i] = randList(byte, rng(0, 255), keyBytes, unique = false)
    vals[i] = randList(byte, rng(0, 255), valBytes, unique = false)
    trie.put(keys[i], vals[i])

  let rootHash = trie.rootHash

  var wb = initWitnessBuilder(memDB, rootHash)
  var witness = wb.getBranchRecurse(keys[0])
  var input = memoryInput(witness)

  var db = newMemoryDB()
  var tb = initTreeBuilder(input, db)
  var root = tb.treeNode()
  debugEcho "root: ", root.data.toHex
  debugEcho "rootHash: ", rootHash.data.toHex
  doAssert root.data == rootHash.data

proc main() =
  runTest(7, 100, 50)
  runTest(1, 1, 1)
  runTest(5, 5, 1)
  runTest(6, 7, 3)
  runTest(7, 10, 7)
  runTest(8, 15, 11)
  runTest(9, 30, 13)
  runTest(11, 40, 10)
  runTest(20, 1, 15)
  runTest(25, 10, 20)

  randomize()
  for i in 0..<30:
    runTest(rand(1..30), rand(1..50), rand(1..30))


main()
