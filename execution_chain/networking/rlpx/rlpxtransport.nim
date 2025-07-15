# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import results, chronos, eth/common/keys, ./[auth, rlpxcrypt, rlpxerror]

export results, keys, rlpxerror

type
  RlpxTransport* = ref object
    stream: StreamTransport
    crypt: RlpxCrypt
    pubkey*: PublicKey

template `^`(arr): auto =
  # passes a stack array with a matching `arrLen` variable as an open array
  arr.toOpenArray(0, `arr Len` - 1)

proc initiatorHandshake(
    rng: ref HmacDrbgContext,
    keys: KeyPair,
    stream: StreamTransport,
    remotePubkey: PublicKey,
): Future[Result[RlpxTransport, RlpxError]] {.async: (raises: [CancelledError]).} =
  # https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md#initial-handshake
  var
    handshake = Handshake.init(rng[], keys, {Initiator})
    authMsg: array[AuthMessageMaxEIP8, byte]

  try:
    let
      authMsgLen = handshake.authMessage(rng[], remotePubkey, authMsg).expect(
          "No errors with correctly sized buffer"
        )

      writeRes = await stream.write(addr authMsg[0], authMsgLen)
    if writeRes != authMsgLen:
      return rlpxError(TransportConnectError, "Could not write RLPx handshake header")

    var ackMsg = newSeqOfCap[byte](1024)
    ackMsg.setLen(MsgLenLenEIP8)
    await stream.readExactly(addr ackMsg[0], len(ackMsg))

    let ackMsgLen = handshake.decodeAckMsgLen(ackMsg).valueOr:
      return rlpxError(ProtocolError, "Could not decode handshake ack length: " & $error)

    ackMsg.setLen(ackMsgLen)
    await stream.readExactly(addr ackMsg[MsgLenLenEIP8], ackMsgLen - MsgLenLenEIP8)

    handshake.decodeAckMessage(ackMsg).isOkOr:
      return rlpxError(ProtocolError, "Could not decode handshake ack: " & $error)

    let
      secrets = handshake.getSecrets(^authMsg, ackMsg)
      transport = RlpxTransport(pubkey: remotePubkey)

    initRlpxCrypt(secrets, transport.crypt)
    ok(transport)
  except TransportError as exc:
    rlpxError(TransportConnectError, exc.msg)

proc responderHandshake(
    rng: ref HmacDrbgContext, keys: KeyPair, stream: StreamTransport
): Future[Result[RlpxTransport, RlpxError]] {.async: (raises: [CancelledError]).} =
  # https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md#initial-handshake
  var
    handshake = Handshake.init(rng[], keys, {auth.Responder})
    authMsg = newSeqOfCap[byte](1024)

  try:
    authMsg.setLen(MsgLenLenEIP8)
    await stream.readExactly(addr authMsg[0], len(authMsg))

    let authMsgLen = handshake.decodeAuthMsgLen(authMsg).valueOr:
      return rlpxError(ProtocolError,  "Could not decode handshake auth length: " & $error)

    authMsg.setLen(authMsgLen)
    await stream.readExactly(addr authMsg[MsgLenLenEIP8], authMsgLen - MsgLenLenEIP8)

    handshake.decodeAuthMessage(authMsg).isOkOr:
      return rlpxError(ProtocolError, "Could not decode handshake auth message: " & $error)

    var ackMsg: array[AckMessageMaxEIP8, byte]
    let ackMsgLen =
      handshake.ackMessage(rng[], ackMsg).expect("no errors with correcly sized buffer")

    var res = await stream.write(addr ackMsg[0], ackMsgLen)
    if res != ackMsgLen:
      return rlpxError(TransportConnectError, "Could not write RLPx ack message")

    let
      secrets = handshake.getSecrets(authMsg, ^ackMsg)
      transport = RlpxTransport(pubkey: handshake.remoteHPubkey)

    initRlpxCrypt(secrets, transport.crypt)
    ok(transport)
  except TransportError as exc:
    rlpxError(TransportConnectError, exc.msg)

proc connect*(
    _: type RlpxTransport,
    rng: ref HmacDrbgContext,
    keys: KeyPair,
    address: TransportAddress,
    remotePubkey: PublicKey,
): Future[Result[RlpxTransport, RlpxError]] {.async: (raises: [CancelledError]).} =
  var stream: StreamTransport
  try:
    stream = await connect(address)
    let transport = (await initiatorHandshake(rng, keys, stream, remotePubkey)).valueOr:
      return err(error)
    transport.stream = move(stream)
    ok(transport)
  except TransportError as exc:
    rlpxError(TransportConnectError, exc.msg)
  finally:
    if stream != nil:
      stream.close()

proc accept*(
    _: type RlpxTransport,
    rng: ref HmacDrbgContext,
    keys: KeyPair,
    stream: StreamTransport,
): Future[Result[RlpxTransport, RlpxError]] {.async: (raises: [CancelledError]).} =
  var stream = stream
  try:
    let transport = (await responderHandshake(rng, keys, stream)).valueOr:
      return err(error)
    transport.stream = move(stream)
    ok(transport)
  finally:
    if stream != nil:
      stream.close()

proc recvMsg*(
    transport: RlpxTransport
): Future[Result[seq[byte], RlpxError]] {.async: (raises: [CancelledError]).} =
  try:
    ## Read an RLPx frame from the given peer
    var msgHeaderEnc: RlpxEncryptedHeader
    await transport.stream.readExactly(addr msgHeaderEnc[0], msgHeaderEnc.len)

    let
      msgHeader = decryptHeader(transport.crypt, msgHeaderEnc).valueOr:
        return rlpxError(ProtocolError, "Cannot decrypt RLPx frame header")

      # The header has more fields than the size, but they are unused / obsolete.
      # Although some clients set them, we don't check this in the spirit of EIP-8
      # https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md#framing
      msgSize = msgHeader.getBodySize()
      remainingBytes = encryptedLength(msgSize) - 32

    var encryptedBytes = newSeq[byte](remainingBytes)
    await transport.stream.readExactly(addr encryptedBytes[0], len(encryptedBytes))

    let decryptedMaxLength = decryptedLength(msgSize) # Padded length
    var msgBody = newSeq[byte](decryptedMaxLength)

    decryptBody(transport.crypt, encryptedBytes, msgSize, msgBody).isOkOr():
      return rlpxError(ProtocolError, "Cannot decrypt message body")

    reset(encryptedBytes) # Release memory (TODO: in-place decryption)

    msgBody.setLen(msgSize) # Remove padding
    ok(msgBody)
  except TransportError as exc:
    rlpxError(TransportConnectError, exc.msg)

proc sendMsg*(
    transport: RlpxTransport, data: seq[byte]
): Future[Result[void, RlpxError]] {.async: (raises: [CancelledError]).} =
  try:
    let
      cipherText = encryptMsg(data, transport.crypt)
      res = await transport.stream.write(cipherText)

    if res != len(cipherText):
      return rlpxError(TransportConnectError, "Could not complete writing message")

    ok()
  except TransportError as exc:
    rlpxError(TransportConnectError, exc.msg)

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

  let client = (waitFor RlpxTransport.connect(
    rng,
    kp,
    initTAddress(paramStr(1), parseInt(paramStr(2))),
    PublicKey.fromHex(paramStr(3))[],
  )).valueOr:
    echo "Connect error: ", error.msg
    quit 1

  proc encodeMsg(msgId: uint64, msg: auto): seq[byte] =
    var rlpWriter = initRlpWriter()
    rlpWriter.append msgId
    rlpWriter.appendRecordType(msg, typeof(msg).rlpFieldsCount > 1)
    rlpWriter.finish

  (waitFor client.sendMsg(
    encodeMsg(
      uint64 0, (uint64 4, "nimbus", @[("eth", uint64 68)], uint64 0, kp.pubkey.toRaw())
    )
  )).isOkOr:
    echo "sendMsg error: ", error.msg
    quit 1

  while true:
    echo "Reading message"
    var data = (waitFor client.recvMsg()).valueOr:
      echo "recvMsg error: ", error.msg
      quit 1
    var rlp = rlpFromBytes(data)
    let msgId = rlp.read(uint64)
    if msgId == 0:
      echo "Hello: ",
        rlp.read((uint64, string, seq[(string, uint64)], uint64, seq[byte]))
    else:
      echo "Unknown message ", msgId, " ", toHex(data)
