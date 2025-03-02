# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import results, chronos, eth/common/keys, ./[auth, rlpxcrypt]

export results, keys

type
  RlpxTransport* = ref object
    stream: StreamTransport
    state: SecretState
    pubkey*: PublicKey

  RlpxTransportError* = object of CatchableError

template `^`(arr): auto =
  # passes a stack array with a matching `arrLen` variable as an open array
  arr.toOpenArray(0, `arr Len` - 1)

proc initiatorHandshake(
    rng: ref HmacDrbgContext,
    keys: KeyPair,
    stream: StreamTransport,
    remotePubkey: PublicKey,
): Future[ConnectionSecret] {.
    async: (raises: [CancelledError, TransportError, RlpxTransportError])
.} =
  # https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md#initial-handshake
  var
    handshake = Handshake.init(rng[], keys, {Initiator})
    authMsg: array[AuthMessageMaxEIP8, byte]

  let
    authMsgLen = handshake.authMessage(rng[], remotePubkey, authMsg).expect(
        "No errors with correctly sized buffer"
      )

    writeRes = await stream.write(addr authMsg[0], authMsgLen)
  if writeRes != authMsgLen:
    # TOOD raising a chronos error here is a hack - rework using something else
    raise (ref TransportIncompleteError)(msg: "Could not write RLPx handshake header")

  var ackMsg = newSeqOfCap[byte](1024)
  ackMsg.setLen(MsgLenLenEIP8)
  await stream.readExactly(addr ackMsg[0], len(ackMsg))

  let ackMsgLen = handshake.decodeAckMsgLen(ackMsg).valueOr:
    raise
      (ref RlpxTransportError)(msg: "Could not decode handshake ack length: " & $error)

  ackMsg.setLen(ackMsgLen)
  await stream.readExactly(addr ackMsg[MsgLenLenEIP8], ackMsgLen - MsgLenLenEIP8)

  handshake.decodeAckMessage(ackMsg).isOkOr:
    raise (ref RlpxTransportError)(msg: "Could not decode handshake ack: " & $error)

  handshake.getSecrets(^authMsg, ackMsg)

proc responderHandshake(
    rng: ref HmacDrbgContext, keys: KeyPair, stream: StreamTransport
): Future[(ConnectionSecret, PublicKey)] {.
    async: (raises: [CancelledError, TransportError, RlpxTransportError])
.} =
  # https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md#initial-handshake
  var
    handshake = Handshake.init(rng[], keys, {auth.Responder})
    authMsg = newSeqOfCap[byte](1024)

  authMsg.setLen(MsgLenLenEIP8)
  await stream.readExactly(addr authMsg[0], len(authMsg))

  let authMsgLen = handshake.decodeAuthMsgLen(authMsg).valueOr:
    raise
      (ref RlpxTransportError)(msg: "Could not decode handshake auth length: " & $error)

  authMsg.setLen(authMsgLen)
  await stream.readExactly(addr authMsg[MsgLenLenEIP8], authMsgLen - MsgLenLenEIP8)

  handshake.decodeAuthMessage(authMsg).isOkOr:
    raise (ref RlpxTransportError)(
      msg: "Could not decode handshake auth message: " & $error
    )

  var ackMsg: array[AckMessageMaxEIP8, byte]
  let ackMsgLen =
    handshake.ackMessage(rng[], ackMsg).expect("no errors with correcly sized buffer")

  var res = await stream.write(addr ackMsg[0], ackMsgLen)
  if res != ackMsgLen:
    # TOOD raising a chronos error here is a hack - rework using something else
    raise (ref TransportIncompleteError)(msg: "Could not write RLPx ack message")

  (handshake.getSecrets(authMsg, ^ackMsg), handshake.remoteHPubkey)

proc connect*(
    _: type RlpxTransport,
    rng: ref HmacDrbgContext,
    keys: KeyPair,
    address: TransportAddress,
    remotePubkey: PublicKey,
): Future[RlpxTransport] {.
    async: (raises: [CancelledError, TransportError, RlpxTransportError])
.} =
  var stream = await connect(address)

  try:
    let secrets = await initiatorHandshake(rng, keys, stream, remotePubkey)
    var res = RlpxTransport(stream: move(stream), pubkey: remotePubkey)
    initSecretState(secrets, res.state)
    res
  finally:
    if stream != nil:
      stream.close()

proc accept*(
    _: type RlpxTransport,
    rng: ref HmacDrbgContext,
    keys: KeyPair,
    stream: StreamTransport,
): Future[RlpxTransport] {.
    async: (raises: [CancelledError, TransportError, RlpxTransportError])
.} =
  var stream = stream
  try:
    let (secrets, remotePubkey) = await responderHandshake(rng, keys, stream)
    var res = RlpxTransport(stream: move(stream), pubkey: remotePubkey)
    initSecretState(secrets, res.state)
    res
  finally:
    if stream != nil:
      stream.close()

proc recvMsg*(
    transport: RlpxTransport
): Future[seq[byte]] {.
    async: (raises: [CancelledError, TransportError, RlpxTransportError])
.} =
  ## Read an RLPx frame from the given peer
  var msgHeaderEnc: RlpxEncryptedHeader
  await transport.stream.readExactly(addr msgHeaderEnc[0], msgHeaderEnc.len)

  let msgHeader = decryptHeader(transport.state, msgHeaderEnc).valueOr:
    raise (ref RlpxTransportError)(msg: "Cannot decrypt RLPx frame header")

  # The header has more fields than the size, but they are unused / obsolete.
  # Although some clients set them, we don't check this in the spirit of EIP-8
  # https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md#framing

  let msgSize = msgHeader.getBodySize()
  let remainingBytes = encryptedLength(msgSize) - 32

  var encryptedBytes = newSeq[byte](remainingBytes)
  await transport.stream.readExactly(addr encryptedBytes[0], len(encryptedBytes))

  let decryptedMaxLength = decryptedLength(msgSize) # Padded length
  var msgBody = newSeq[byte](decryptedMaxLength)

  if decryptBody(transport.state, encryptedBytes, msgSize, msgBody).isErr():
    raise (ref RlpxTransportError)(msg: "Cannot decrypt message body")

  reset(encryptedBytes) # Release memory (TODO: in-place decryption)

  msgBody.setLen(msgSize) # Remove padding
  msgBody

proc sendMsg*(
    transport: RlpxTransport, data: seq[byte]
) {.async: (raises: [CancelledError, TransportError, RlpxTransportError]).} =
  let cipherText = encryptMsg(data, transport.state)
  var res = await transport.stream.write(cipherText)
  if res != len(cipherText):
    # TOOD raising a chronos error here is a hack - rework using something else
    raise (ref TransportIncompleteError)(msg: "Could not complete writing message")

proc remoteAddress*(
    transport: RlpxTransport
): TransportAddress {.raises: [TransportOsError].} =
  transport.stream.remoteAddress()

proc closed*(transport: RlpxTransport): bool =
  transport.stream != nil and transport.stream.closed

proc close*(transport: RlpxTransport) =
  if transport.stream != nil:
    transport.stream.close()

proc closeWait*(
    transport: RlpxTransport
): Future[void] {.async: (raises: [], raw: true).} =
  transport.stream.closeWait()

when isMainModule:
  # Simple CLI application for negotiating an RLPx connection with a peer

  import stew/byteutils, std/cmdline, std/strutils, eth/rlp
  if paramCount() < 3:
    echo "rlpxtransport ip port pubkey"
    quit 1

  let
    rng = newRng()
    kp = KeyPair.random(rng[])

  echo "Local key: ", toHex(kp.pubkey.toRaw())

  let client = waitFor RlpxTransport.connect(
    rng,
    kp,
    initTAddress(paramStr(1), parseInt(paramStr(2))),
    PublicKey.fromHex(paramStr(3))[],
  )

  proc encodeMsg(msgId: uint64, msg: auto): seq[byte] =
    var rlpWriter = initRlpWriter()
    rlpWriter.append msgId
    rlpWriter.appendRecordType(msg, typeof(msg).rlpFieldsCount > 1)
    rlpWriter.finish

  waitFor client.sendMsg(
    encodeMsg(
      uint64 0, (uint64 4, "nimbus", @[("eth", uint64 68)], uint64 0, kp.pubkey.toRaw())
    )
  )

  while true:
    echo "Reading message"
    var data = waitFor client.recvMsg()
    var rlp = rlpFromBytes(data)
    let msgId = rlp.read(uint64)
    if msgId == 0:
      echo "Hello: ",
        rlp.read((uint64, string, seq[(string, uint64)], uint64, seq[byte]))
    else:
      echo "Unknown message ", msgId, " ", toHex(data)
