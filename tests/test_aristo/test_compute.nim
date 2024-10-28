# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/[algorithm, sets],
  stew/byteutils,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_check,
    aristo_compute,
    aristo_delete,
    aristo_get,
    aristo_merge,
    aristo_desc,
    aristo_utils,
    aristo_serialise,
    aristo_init,
    aristo_tx/tx_stow,
  ]

func x(s: string): seq[byte] =
  s.hexToSeqByte
func k(s: string): HashKey =
  HashKey.fromBytes(s.x).value

let samples = [
  # Somew on-the-fly provided stuff
  @[
    # Create leaf node
    (
      hash32"0000000000000000000000000000000000000000000000000000000000000001",
      AristoAccount(balance: 0.u256, codeHash: EMPTY_CODE_HASH),
      hash32"69b5c560f84dde1ecb0584976f4ebbe78e34bb6f32410777309a8693424bb563",
    ),
    # Overwrite existing leaf
    (
      hash32"0000000000000000000000000000000000000000000000000000000000000001",
      AristoAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH),
      hash32"5ce3c539427b494d97d1fc89080118370f173d29c7dec55a292e6c00a08c4465",
    ),
    # Split leaf node with extension
    (
      hash32"0000000000000000000000000000000000000000000000000000000000000002",
      AristoAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH),
      hash32"6f28eee5fe67fba78c5bb42cbf6303574c4139ad97631002e07466d2f98c0d35",
    ),
    (
      hash32"0000000000000000000000000000000000000000000000000000000000000003",
      AristoAccount(balance: 0.u256, codeHash: EMPTY_CODE_HASH),
      hash32"5dacbc38677935c135b911e8c786444e4dc297db1f0c77775ce47ffb8ce81dca",
    ),
    # Split extension
    (
      hash32"0100000000000000000000000000000000000000000000000000000000000000",
      AristoAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH),
      hash32"57dd53adbbd1969204c0b3435df8c22e0aadadad50871ce7ab4d802b77da2dd3",
    ),
    (
      hash32"0100000000000000000000000000000000000000000000000000000000000001",
      AristoAccount(balance: 2.u256, codeHash: EMPTY_CODE_HASH),
      hash32"67ebbac82cc2a55e0758299f63b785fbd3d1f17197b99c78ffd79d73d3026827",
    ),
    (
      hash32"0200000000000000000000000000000000000000000000000000000000000000",
      AristoAccount(balance: 3.u256, codeHash: EMPTY_CODE_HASH),
      hash32"e7d6a8f7fb3e936eff91a5f62b96177817f2f45a105b729ab54819a99a353325",
    ),
  ]
]

suite "Aristo compute":
  for n, sample in samples:
    test "Add and delete entries " & $n:
      let
        db = AristoDbRef.init VoidBackendRef
        root = VertexID(1)

      for (k, v, r) in sample:
        checkpoint("k = " & k.toHex & ", v = " & $v)

        check:
          db.mergeAccountRecord(k, v) == Result[bool, AristoError].ok(true)

        # Check state against expected value
        let w = db.computeKey((root, root)).expect("no errors")
        check r == w.to(Hash32)

        let rc = db.check
        check rc == typeof(rc).ok()

      # Reverse run deleting entries
      var deletedKeys: HashSet[Hash32]
      for iny, (k, v, r) in sample.reversed:
        # Check whether key was already deleted
        if k in deletedKeys:
          continue
        deletedKeys.incl k

        # Check state against expected value
        let w = db.computeKey((root, root)).value.to(Hash32)

        check r == w

        check:
          db.deleteAccountRecord(k).isOk

        let rc = db.check
        check rc == typeof(rc).ok()

  test "Pre-computed key":
    # TODO use mainnet genesis in this test?
    let
      db = AristoDbRef.init MemBackendRef
      root = VertexID(1)

    for (k, v, r) in samples[^1]:
      check:
        db.mergeAccountRecord(k, v) == Result[bool, AristoError].ok(true)

    check db.txStow(1, true).isOk()

    check db.computeKeys(root).isOk()

    let w = db.computeKey((root, root)).value.to(Hash32)
    check w == samples[^1][^1][2]
