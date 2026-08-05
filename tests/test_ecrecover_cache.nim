# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  std/sequtils,
  unittest2,
  taskpools,
  ../execution_chain/transaction,
  ../execution_chain/utils/ecrecover_cache,
  eth/common/[eth_types_rlp, keys, transaction_utils]

const recipient = address"0x0000000000000000000000000000000000000042"

let
  senderKey = PrivateKey.fromHex(
    "af1a9be9f1a54421cac82943820a0fe0f601bb5f4f6d0bccc81c613f0ce6ae22"
  )[]
  otherKey = PrivateKey.fromHex(
    "3ff4cbc0e3faa3d0d6b1f7ad5a7f2b83e69b46ab3e0dd0b1e9d1a1ad1b0e0f01"
  )[]

proc makeTx(nonce: uint64, key = senderKey): Transaction =
  let tx = Transaction(
    txType: TxLegacy,
    chainId: 1.u256.ChainId,
    nonce: AccountNonce(nonce),
    gasPrice: 1_000_000_000,
    gasLimit: 21_000,
    to: Opt.some(recipient),
    value: 1.u256,
  )
  signTransaction(tx, key, eip155 = true)

proc signedMsg(seed: byte, key = senderKey): (Hash32, Signature, Address) =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = seed xor byte(i * 7 + 1)
  (Hash32(Bytes32(raw)), sign(key, SkMessage(raw)), key.toPublicKey().to(Address))

proc recoverTask(tx: ptr Transaction): Address {.nimcall.} =
  tx[].recoverSenderCached().valueOr(zeroAddress)

suite "Sender recovery cache":
  test "usable without any explicit setup":
    let tx = makeTx(1000)
    check tx.recoverSenderCached() == tx.recoverSender()

  test "repeated lookups agree with an uncached recovery":
    let
      tx = makeTx(1001)
      expected = tx.recoverSender()

    check:
      expected.isSome()
      tx.recoverSenderCached() == expected
      tx.recoverSenderCached() == expected

  test "distinct transactions get distinct senders":
    let
      a = makeTx(1003, senderKey)
      b = makeTx(1003, otherKey)

    check:
      a.recoverSenderCached() == a.recoverSender()
      b.recoverSenderCached() == b.recoverSender()
      a.recoverSenderCached() != b.recoverSenderCached()

  test "an invalid signature stays a miss":
    var tx = makeTx(1005)
    tx.R = 0.u256

    check:
      tx.recoverSender().isNone()
      tx.recoverSenderCached().isNone()
      tx.recoverSenderCached().isNone()

  test "answers stay correct across many entries":
    let txs = (2000'u64 .. 2255'u64).toSeq().mapIt(makeTx(it))
    for tx in txs:
      check tx.recoverSenderCached() == tx.recoverSender()

    for i in countdown(txs.high, 0):
      check txs[i].recoverSenderCached() == txs[i].recoverSender()

  test "concurrent lookups from taskpool threads":
    var
      tp = Taskpool.new(numThreads = 4)
      txs = (3000'u64 .. 3063'u64).toSeq().mapIt(makeTx(it))
      expected = txs.mapIt(it.recoverSender().valueOr(zeroAddress))

    var futs: seq[Flowvar[Address]]
    for _ in 0 ..< 4:
      for i in 0 .. txs.high:
        let txPtr = txs[i].addr
        futs.add tp.spawn recoverTask(txPtr)

    for i, f in futs.mpairs():
      check sync(f) == expected[i mod expected.len]

    tp.shutdown()

suite "ecRecover precompile cache":
  test "repeated lookups return the signer":
    let (msgHash, sig, expected) = signedMsg(0x11)

    check:
      recoverSenderCached(msgHash, sig) == Opt.some(expected)
      recoverSenderCached(msgHash, sig) == Opt.some(expected)

  test "a different message with the same signature recovers differently":
    let (msgHash, sig, expected) = signedMsg(0x22)
    var other = msgHash
    other.data[0] = other.data[0] xor 0xff'u8

    check:
      recoverSenderCached(msgHash, sig) == Opt.some(expected)
      recoverSenderCached(other, sig) != Opt.some(expected)

  test "a different signer over the same message recovers differently":
    let
      (msgHash, sig, expected) = signedMsg(0x33, senderKey)
      (_, otherSig, otherExpected) = signedMsg(0x33, otherKey)

    check:
      expected != otherExpected
      recoverSenderCached(msgHash, sig) == Opt.some(expected)
      recoverSenderCached(msgHash, otherSig) == Opt.some(otherExpected)
