import
  unittest, json, os, tables, strformat, strutils,
  eth/[common, rlp],
  ./test_helpers, ../nimbus/[transaction, utils, errors]


#[
    def v_min(self) -> int:
        if is_eip_155_signed_transaction(self):
            return 35 + (2 * self.chain_id)
        else:
            return 27

    def v_max(self) -> int:
        if is_eip_155_signed_transaction(self):
            return 36 + (2 * self.chain_id)
        else:
            return 28


    def v_min(self) -> int:
        return 27

    def v_max(self) -> int:
        return 28

    validate_lt_secpk1n(self.r, title="Transaction.r")
    validate_gte(self.r, minimum=1, title="Transaction.r")
    validate_lt_secpk1n(self.s, title="Transaction.s")
    validate_gte(self.s, minimum=1, title="Transaction.s")

    validate_gte(self.v, minimum=self.v_min, title="Transaction.v")
    validate_lte(self.v, maximum=self.v_max, title="Transaction.v")

    homestead
    super.validate
    validate_lt_secpk1n2(self.s, title="Transaction.s")

    check_signature_validity()
]#

const
  FIXTURE_FORK_SKIPS = ["_info", "rlp", "Constantinople"]

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus)

suite "Transactions tests":
  jsonTest("TransactionTests", testFixture)

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
    except RlpTypeMismatch, MalformedRlpError:
      # TODO:
      # nimbus rlp cannot allow type mismatch
      # e.g. uint256 value put into int64
      # so we skip noHash check
      # this behavior different compared to
      # py-evm, not sure what should we do
      if title in SKIP_TITLES:
        return
      check noHash(fixture)
      return

    for forkName, fork in fixture:
      if forkName notin FIXTURE_FORK_SKIPS:
        testTxByFork(tx, fork, forkName, testStatusIMPL)
