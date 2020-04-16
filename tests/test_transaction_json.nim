import
  unittest2, json, os, tables, strutils,
  eth/[common, rlp],
  ./test_helpers,
  ../nimbus/[transaction, utils, errors]

const
  FIXTURE_FORK_SKIPS = ["_info", "rlp", "Constantinople"]

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus)

proc transactionJsonMain*() =
  suite "Transactions tests":
    jsonTest("TransactionTests", testFixture)

when isMainModule:
  transactionJsonMain()

proc txHash(tx: Transaction): string =
  toLowerAscii($keccakHash(rlp.encode(tx)))

proc testTxByFork(tx: Transaction, forkData: JsonNode, forkName: string, testStatusIMPL: var TestStatus) =
  try:
    tx.validate(nameToFork[forkName])
  except ValidationError:
    return

  if forkData.len > 0 and "sender" in forkData:
    let sender = ethAddressFromHex(forkData["sender"].getStr)
    check "hash" in forkData
    check tx.txHash == forkData["hash"].getStr
    check tx.getSender == sender

func noHash(fixture: JsonNode): bool =
  result = true
  for forkName, forkData in fixture:
    if forkName notin FIXTURE_FORK_SKIPS:
      if forkData.len == 0: return
      if "hash" in forkData: return false

# nimbus rlp cannot allow type mismatch
# e.g. uint256 value put into int64
# so we skip noHash check. this behavior
# is different compared to py-evm
const SKIP_TITLES = [
  "TransactionWithGasLimitxPriceOverflow",
  "TransactionWithHighNonce256",
  "TransactionWithHighGasPrice",
  "V_equals38"
  ]

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus) =
  var
    title: string
    rlpData: seq[byte]
    tx: Transaction

  for key, fixture in node:
    title = key

    try:
      rlpData = safeHexToSeqByte(fixture["rlp"].getStr)
    except ValueError:
      # bad rlp bytes
      check noHash(fixture)
      return

    try:
      tx = rlp.decode(rlpData, Transaction)
    except RlpTypeMismatch, MalformedRlpError, UnsupportedRlpError:
      if title in SKIP_TITLES:
        return
      check noHash(fixture)
      return

    for forkName, fork in fixture:
      if forkName notin FIXTURE_FORK_SKIPS:
        testTxByFork(tx, fork, forkName, testStatusIMPL)
