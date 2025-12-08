# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements Ethereum EIP-8 RLPx authentication - pre-EIP-8
## messages are not supported
## https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md#initial-handshake
## https://github.com/ethereum/EIPs/blob/b479473414cf94445b450c266a9dedc079a12158/EIPS/eip-8.md

{.push raises: [].}

import
  nimcrypto/[rijndael, utils],
  stew/[arrayops, byteutils, endians2, objects],
  results,
  eth/rlp,
  eth/keccak/keccak,
  eth/common/keys,
  ./ecies

export results

const
  # Auth message sizes
  MsgLenLenEIP8* = 2
    ## auth-size = size of enc-auth-body, encoded as a big-endian 16-bit integer
    ## ack-size = size of enc-ack-body, encoded as a big-endian 16-bit integer

  MinPadLenEIP8* = 100
  MaxPadLenEIP8* = 300
    ## Padding makes message length unpredictable which makes packet filtering
    ## a tiny bit harder - although not necessary any more, we always add at
    ## least 100 bytes of padding to make the message distinguishable from
    ## pre-EIP8 and at most 200 to stay within recommendation

  # signature + pubkey + nonce + version + rlp encoding overhead
  # 65 + 64 + 32 + 1 + 7 = 169
  PlainAuthMessageEIP8Length = 169
  PlainAuthMessageMaxEIP8 = PlainAuthMessageEIP8Length + MaxPadLenEIP8
  # Min. encrypted message + size prefix = 284
  AuthMessageEIP8Length* =
    eciesEncryptedLength(PlainAuthMessageEIP8Length) + MsgLenLenEIP8
  AuthMessageMaxEIP8* = AuthMessageEIP8Length + MaxPadLenEIP8
    ## Minimal output buffer size to pass into `authMessage`

  # Ack message sizes

  # pubkey + nounce + version + rlp encoding overhead
  # 64 + 32 + 1 + 5 = 102
  PlainAckMessageEIP8Length = 102
  PlainAckMessageMaxEIP8 = PlainAckMessageEIP8Length + MaxPadLenEIP8
  # Min. encrypted message + size prefix = 217
  AckMessageEIP8Length* =
    eciesEncryptedLength(PlainAckMessageEIP8Length) + MsgLenLenEIP8
  AckMessageMaxEIP8* = AckMessageEIP8Length + MaxPadLenEIP8
    ## Minimal output buffer size to pass into `ackMessage`

  Vsn = [byte 4]
    ## auth-vsn = 4
    ## ack-vsn = 4

type
  Keccak256 = keccak.Keccak256
  
  Nonce* = array[KeyLength, byte]

  HandshakeFlag* = enum
    Initiator ## `Handshake` owner is connection initiator
    Responder ## `Handshake` owner is connection responder

  AuthError* = enum
    EcdhError = "auth: ECDH shared secret could not be calculated"
    BufferOverrun = "auth: buffer overrun"
    SignatureError = "auth: signature could not be obtained"
    EciesError = "auth: ECIES encryption/decryption error"
    InvalidPubKey = "auth: invalid public key"
    InvalidAuth = "auth: invalid Authentication message"
    InvalidAck = "auth: invalid Authentication ACK message"
    RlpError = "auth: error while decoding RLP stream"
    IncompleteError = "auth: data incomplete"

  Handshake* = object
    flags*: set[HandshakeFlag] ## handshake flags
    host*: KeyPair ## host keypair
    ephemeral*: KeyPair ## ephemeral host keypair
    remoteHPubkey*: PublicKey ## remote host public key
    remoteEPubkey*: PublicKey ## remote host ephemeral public key
    initiatorNonce*: Nonce ## initiator nonce
    responderNonce*: Nonce ## responder nonce

  ConnectionSecret* = object
    aesKey*: array[aes256.sizeKey, byte]
    macKey*: array[KeyLength, byte]
    egressMac*: Keccak256
    ingressMac*: Keccak256

  AuthResult*[T] = Result[T, AuthError]

template toa(a, b, c: untyped): untyped =
  toOpenArray((a), (b), (b) + (c) - 1)

proc mapErrTo[T, E](r: Result[T, E], v: static AuthError): AuthResult[T] =
  r.mapErr(
    proc(e: E): AuthError =
      v
  )

proc init*(
    T: type Handshake,
    rng: var HmacDrbgContext,
    host: KeyPair,
    flags: set[HandshakeFlag],
): T =
  ## Create new `Handshake` object.
  var
    initiatorNonce: Nonce
    responderNonce: Nonce
    ephemeral = KeyPair.random(rng)

  if Initiator in flags:
    rng.generate(initiatorNonce)
  else:
    rng.generate(responderNonce)

  return T(
    flags: flags,
    host: host,
    ephemeral: ephemeral,
    initiatorNonce: initiatorNonce,
    responderNonce: responderNonce,
  )

proc authMessage*(
    h: var Handshake,
    rng: var HmacDrbgContext,
    pubkey: PublicKey,
    output: var openArray[byte],
): AuthResult[int] =
  ## Create EIP8 authentication message - returns length of encoded message
  ## The output should be a buffer of AuthMessageMaxEIP8 bytes at least.
  if len(output) < AuthMessageMaxEIP8:
    return err(AuthError.BufferOverrun)

  var padsize = int(rng.generate(byte))
  while padsize > (MaxPadLenEIP8 - MinPadLenEIP8):
    padsize = int(rng.generate(byte))
  padsize += MinPadLenEIP8

  let
    pencsize = eciesEncryptedLength(PlainAuthMessageEIP8Length)
    wosize = pencsize + padsize
    fullsize = wosize + 2

  doAssert fullsize <= len(output), "We checked against max possible length above"

  var secret = ecdhSharedSecret(h.host.seckey, pubkey)
  secret.data = secret.data xor h.initiatorNonce

  let signature = sign(h.ephemeral.seckey, SkMessage(secret.data))
  secret.clear()

  h.remoteHPubkey = pubkey
  var payload =
    rlp.encodeList(signature.toRaw(), h.host.pubkey.toRaw(), h.initiatorNonce, Vsn)
  doAssert(len(payload) == PlainAuthMessageEIP8Length)

  var buffer {.noinit.}: array[PlainAuthMessageMaxEIP8, byte]
  copyMem(addr buffer[0], addr payload[0], len(payload))
  rng.generate(toa(buffer, PlainAuthMessageEIP8Length, padsize))

  let wosizeBE = uint16(wosize).toBytesBE()
  output[0 ..< 2] = wosizeBE
  if eciesEncrypt(
    rng,
    toa(buffer, 0, len(payload) + padsize),
    toa(output, 2, wosize),
    pubkey,
    toa(output, 0, 2),
  ).isErr:
    return err(AuthError.EciesError)

  ok(fullsize)

proc ackMessage*(
    h: var Handshake, rng: var HmacDrbgContext, output: var openArray[byte]
): AuthResult[int] =
  ## Create EIP8 authentication ack message - returns length of encoded message
  ## The output should be a buffer of AckMessageMaxEIP8 bytes at least.
  if len(output) < AckMessageMaxEIP8:
    return err(AuthError.BufferOverrun)

  var padsize = int(rng.generate(byte))
  while padsize > (MaxPadLenEIP8 - MinPadLenEIP8):
    padsize = int(rng.generate(byte))
  padsize += MinPadLenEIP8

  let
    pencsize = eciesEncryptedLength(PlainAckMessageEIP8Length)
    wosize = pencsize + padsize
    fullsize = wosize + 2

  doAssert fullsize <= len(output), "We checked against max possible length above"

  var
    buffer: array[PlainAckMessageMaxEIP8, byte]
    payload = rlp.encodeList(h.ephemeral.pubkey.toRaw(), h.responderNonce, Vsn)
  doAssert(len(payload) == PlainAckMessageEIP8Length)

  copyMem(addr buffer[0], addr payload[0], PlainAckMessageEIP8Length)
  rng.generate(toa(buffer, PlainAckMessageEIP8Length, padsize))

  output[0 ..< MsgLenLenEIP8] = uint16(wosize).toBytesBE()

  if eciesEncrypt(
    rng,
    toa(buffer, 0, PlainAckMessageEIP8Length + padsize),
    toa(output, MsgLenLenEIP8, wosize),
    h.remoteHPubkey,
    toa(output, 0, MsgLenLenEIP8),
  ).isErr:
    return err(AuthError.EciesError)
  ok(fullsize)

func decodeMsgLen(input: openArray[byte]): AuthResult[int] =
  if input.len < 2:
    return err(AuthError.IncompleteError)
  ok(int(uint16.fromBytesBE(input)) + 2)

func decodeAuthMsgLen*(h: Handshake, input: openArray[byte]): AuthResult[int] =
  let len = ?decodeMsgLen(input)
  if len < AuthMessageEIP8Length:
    return err(AuthError.IncompleteError)
  ok(len)

func decodeAckMsgLen*(h: Handshake, input: openArray[byte]): AuthResult[int] =
  let len = ?decodeMsgLen(input)
  if len < AckMessageEIP8Length:
    return err(AuthError.IncompleteError)
  ok(len)

proc decodeAuthMessage*(h: var Handshake, m: openArray[byte]): AuthResult[void] =
  ## Decodes EIP-8 AuthMessage.
  let
    expectedLength = ?h.decodeAuthMsgLen(m)
    size = expectedLength - MsgLenLenEIP8

  # Check if the prefixed size is => than the minimum
  if expectedLength < AuthMessageEIP8Length:
    return err(AuthError.IncompleteError)

  if expectedLength > len(m):
    return err(AuthError.IncompleteError)

  let plainLen = eciesDecryptedLength(size).valueOr:
    return err(AuthError.IncompleteError)

  var buffer = newSeq[byte](plainLen)
  if eciesDecrypt(
    toa(m, MsgLenLenEIP8, int(size)), buffer, h.host.seckey, toa(m, 0, MsgLenLenEIP8)
  ).isErr:
    return err(AuthError.EciesError)

  try:
    var reader = rlpFromBytes(buffer)
    if not reader.isList() or reader.listLen() < 4:
      return err(AuthError.InvalidAuth)
    if reader.listElem(0).blobLen != RawSignatureSize:
      return err(AuthError.InvalidAuth)
    if reader.listElem(1).blobLen != RawPublicKeySize:
      return err(AuthError.InvalidAuth)
    if reader.listElem(2).blobLen != KeyLength:
      return err(AuthError.InvalidAuth)
    if reader.listElem(3).blobLen != 1:
      return err(AuthError.InvalidAuth)
    let
      signatureBr = reader.listElem(0).toBytes()
      pubkeyBr = reader.listElem(1).toBytes()
      nonceBr = reader.listElem(2).toBytes()

      signature = ?Signature.fromRaw(signatureBr).mapErrTo(SignatureError)
      pubkey = ?PublicKey.fromRaw(pubkeyBr).mapErrTo(InvalidPubKey)
      nonce = toArray(KeyLength, nonceBr)

    var secret = ecdhSharedSecret(h.host.seckey, pubkey)
    secret.data = secret.data xor nonce

    let recovered = recover(signature, SkMessage(secret.data))
    secret.clear()

    h.remoteEPubkey = ?recovered.mapErrTo(SignatureError)
    h.initiatorNonce = nonce
    h.remoteHPubkey = pubkey
    ok()
  except RlpError:
    err(AuthError.RlpError)

proc decodeAckMessage*(h: var Handshake, m: openArray[byte]): AuthResult[void] =
  ## Decodes EIP-8 AckMessage.
  let
    expectedLength = ?h.decodeAckMsgLen(m)
    size = expectedLength - MsgLenLenEIP8

  # Check if the prefixed size is => than the minimum
  if expectedLength > len(m):
    return err(AuthError.IncompleteError)

  let plainLen = eciesDecryptedLength(size).valueOr:
    return err(AuthError.IncompleteError)

  var buffer = newSeq[byte](plainLen)
  if eciesDecrypt(
    toa(m, MsgLenLenEIP8, size), buffer, h.host.seckey, toa(m, 0, MsgLenLenEIP8)
  ).isErr:
    return err(AuthError.EciesError)
  try:
    var reader = rlpFromBytes(buffer)
    # The last element, the version, is ignored
    if not reader.isList() or reader.listLen() < 3:
      return err(AuthError.InvalidAck)
    if reader.listElem(0).blobLen != RawPublicKeySize:
      return err(AuthError.InvalidAck)
    if reader.listElem(1).blobLen != KeyLength:
      return err(AuthError.InvalidAck)

    let
      pubkeyBr = reader.listElem(0).toBytes()
      nonceBr = reader.listElem(1).toBytes()

    h.remoteEPubkey = ?PublicKey.fromRaw(pubkeyBr).mapErrTo(InvalidPubKey)
    h.responderNonce = toArray(KeyLength, nonceBr)

    ok()
  except RlpError:
    err(AuthError.RlpError)

proc getSecrets*(
    h: Handshake, authmsg: openArray[byte], ackmsg: openArray[byte]
): ConnectionSecret =
  ## Derive secrets from handshake `h` using encrypted AuthMessage `authmsg` and
  ## encrypted AckMessage `ackmsg`.
  var
    ctx0: Keccak256
    ctx1: Keccak256
    mac1: MDigest[256]
    secret: ConnectionSecret

  # ecdhe-secret = ecdh.agree(ephemeral-privkey, remote-ephemeral-pubk)
  var shsec = ecdhSharedSecret(h.ephemeral.seckey, h.remoteEPubkey)

  # shared-secret = keccak(ecdhe-secret || keccak(nonce || initiator-nonce))
  ctx0.init()
  ctx1.init()
  ctx1.update(h.responderNonce)
  ctx1.update(h.initiatorNonce)
  mac1 = ctx1.finish()
  ctx1.clear()
  ctx0.update(shsec.data)
  ctx0.update(mac1.data)
  mac1 = ctx0.finish()

  # aes-secret = keccak(ecdhe-secret || shared-secret)
  ctx0.init()
  ctx0.update(shsec.data)
  ctx0.update(mac1.data)
  mac1 = ctx0.finish()

  # mac-secret = keccak(ecdhe-secret || aes-secret)
  ctx0.init()
  ctx0.update(shsec.data)
  ctx0.update(mac1.data)
  secret.aesKey = mac1.data
  mac1 = ctx0.finish()
  secret.macKey = mac1.data

  clear(shsec)

  # egress-mac = keccak256(mac-secret ^ recipient-nonce || auth-sent-init)

  var xornonce = mac1.data xor h.responderNonce
  ctx0.init()
  ctx0.update(xornonce)
  ctx0.update(authmsg)

  # ingress-mac = keccak256(mac-secret ^ initiator-nonce || auth-recvd-ack)
  xornonce = secret.macKey xor h.initiatorNonce

  ctx1.init()
  ctx1.update(xornonce)
  ctx1.update(ackmsg)
  burnMem(xornonce)

  if Initiator in h.flags:
    secret.egressMac = ctx0
    secret.ingressMac = ctx1
  else:
    secret.ingressMac = ctx0
    secret.egressMac = ctx1

  ctx0.clear()
  ctx1.clear()

  secret
