# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  unittest2,
  nimcrypto/[utils, keccak],
  eth/common/keys,
  ../../execution_chain/networking/rlpx/auth

# These test vectors were copied from EIP8 specification
# https://github.com/ethereum/EIPs/blob/master/EIPS/eip-8.md
const eip8data = [
  ("initiator_private_key",
   "49a7b37aa6f6645917e7b807e9d1c00d4fa71f18343b0d4122a4d2df64dd6fee"),
  ("receiver_private_key",
   "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291"),
  ("initiator_ephemeral_private_key",
   "869d6ecf5211f1cc60418a13b9d870b22959d0c16f02bec714c960dd2298a32d"),
  ("receiver_ephemeral_private_key",
   "e238eb8e04fee6511ab04c6dd3c89ce097b11f25d584863ac2b6d5b35b1847e4"),
  ("initiator_nonce",
   "7e968bba13b6c50e2c4cd7f241cc0d64d1ac25c7f5952df231ac6a2bda8ee5d6"),
  ("receiver_nonce",
   "559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd"),
  ("auth_ciphertext_eip8",
   """01b304ab7578555167be8154d5cc456f567d5ba302662433674222360f08d5f15
      34499d3678b513b0fca474f3a514b18e75683032eb63fccb16c156dc6eb2c0b15
      93f0d84ac74f6e475f1b8d56116b849634a8c458705bf83a626ea0384d4d7341a
      ae591fae42ce6bd5c850bfe0b999a694a49bbbaf3ef6cda61110601d3b4c02ab6
      c30437257a6e0117792631a4b47c1d52fc0f8f89caadeb7d02770bf999cc147d2
      df3b62e1ffb2c9d8c125a3984865356266bca11ce7d3a688663a51d82defaa8aa
      d69da39ab6d5470e81ec5f2a7a47fb865ff7cca21516f9299a07b1bc63ba56c7a
      1a892112841ca44b6e0034dee70c9adabc15d76a54f443593fafdc3b27af80597
      03f88928e199cb122362a4b35f62386da7caad09c001edaeb5f8a06d2b26fb6cb
      93c52a9fca51853b68193916982358fe1e5369e249875bb8d0d0ec36f917bc5e1
      eafd5896d46bd61ff23f1a863a8a8dcd54c7b109b771c8e61ec9c8908c733c026
      3440e2aa067241aaa433f0bb053c7b31a838504b148f570c0ad62837129e54767
      8c5190341e4f1693956c3bf7678318e2d5b5340c9e488eefea198576344afbdf6
      6db5f51204a6961a63ce072c8926c"""),
  ("auth_ciphertext_eip8_3f",
   """01b8044c6c312173685d1edd268aa95e1d495474c6959bcdd10067ba4c9013df9
      e40ff45f5bfd6f72471f93a91b493f8e00abc4b80f682973de715d77ba3a005a2
      42eb859f9a211d93a347fa64b597bf280a6b88e26299cf263b01b8dfdb7122784
      64fd1c25840b995e84d367d743f66c0e54a586725b7bbf12acca27170ae3283c1
      073adda4b6d79f27656993aefccf16e0d0409fe07db2dc398a1b7e8ee93bcd181
      485fd332f381d6a050fba4c7641a5112ac1b0b61168d20f01b479e19adf7fdbfa
      0905f63352bfc7e23cf3357657455119d879c78d3cf8c8c06375f3f7d4861aa02
      a122467e069acaf513025ff196641f6d2810ce493f51bee9c966b15c504350535
      0392b57645385a18c78f14669cc4d960446c17571b7c5d725021babbcd786957f
      3d17089c084907bda22c2b2675b4378b114c601d858802a55345a15116bc61da4
      193996187ed70d16730e9ae6b3bb8787ebcaea1871d850997ddc08b4f4ea668fb
      f37407ac044b55be0908ecb94d4ed172ece66fd31bfdadf2b97a8bc690163ee11
      f5b575a4b44e36e2bfb2f0fce91676fd64c7773bac6a003f481fddd0bae0a1f31
      aa27504e2a533af4cef3b623f4791b2cca6d490"""),
  ("authack_ciphertext_eip8",
   """01ea0451958701280a56482929d3b0757da8f7fbe5286784beead59d95089c217
      c9b917788989470b0e330cc6e4fb383c0340ed85fab836ec9fb8a49672712aeab
      bdfd1e837c1ff4cace34311cd7f4de05d59279e3524ab26ef753a0095637ac88f
      2b499b9914b5f64e143eae548a1066e14cd2f4bd7f814c4652f11b254f8a2d019
      1e2f5546fae6055694aed14d906df79ad3b407d94692694e259191cde171ad542
      fc588fa2b7333313d82a9f887332f1dfc36cea03f831cb9a23fea05b33deb999e
      85489e645f6aab1872475d488d7bd6c7c120caf28dbfc5d6833888155ed69d34d
      bdc39c1f299be1057810f34fbe754d021bfca14dc989753d61c413d261934e1a9
      c67ee060a25eefb54e81a4d14baff922180c395d3f998d70f46f6b58306f96962
      7ae364497e73fc27f6d17ae45a413d322cb8814276be6ddd13b885b201b943213
      656cde498fa0e9ddc8e0b8f8a53824fbd82254f3e2c17e8eaea009c38b4aa0a3f
      306e8797db43c25d68e86f262e564086f59a2fc60511c42abfb3057c247a8a8fe
      4fb3ccbadde17514b7ac8000cdb6a912778426260c47f38919a91f25f4b5ffb45
      5d6aaaf150f7e5529c100ce62d6d92826a71778d809bdf60232ae21ce8a437eca
      8223f45ac37f6487452ce626f549b3b5fdee26afd2072e4bc75833c2464c80524
      6155289f4"""),
  ("authack_ciphertext_eip8_3f",
   """01f004076e58aae772bb101ab1a8e64e01ee96e64857ce82b1113817c6cdd52c0
      9d26f7b90981cd7ae835aeac72e1573b8a0225dd56d157a010846d888dac7464b
      af53f2ad4e3d584531fa203658fab03a06c9fd5e35737e417bc28c1cbf5e5dfc6
      66de7090f69c3b29754725f84f75382891c561040ea1ddc0d8f381ed1b9d0d4ad
      2a0ec021421d847820d6fa0ba66eaf58175f1b235e851c7e2124069fbc202888d
      db3ac4d56bcbd1b9b7eab59e78f2e2d400905050f4a92dec1c4bdf797b3fc9b2f
      8e84a482f3d800386186712dae00d5c386ec9387a5e9c9a1aca5a573ca91082c7
      d68421f388e79127a5177d4f8590237364fd348c9611fa39f78dcdceee3f390f0
      7991b7b47e1daa3ebcb6ccc9607811cb17ce51f1c8c2c5098dbdd28fca547b3f5
      8c01a424ac05f869f49c6a34672ea2cbbc558428aa1fe48bbfd61158b1b735a65
      d99f21e70dbc020bfdface9f724a0d1fb5895db971cc81aa7608baa0920abb0a5
      65c9c436e2fd13323428296c86385f2384e408a31e104670df0791d93e743a3a5
      194ee6b076fb6323ca593011b7348c16cf58f66b9633906ba54a2ee803187344b
      394f75dd2e663a57b956cb830dd7a908d4f39a2336a61ef9fda549180d4ccde21
      514d117b6c6fd07a9102b5efe710a32af4eeacae2cb3b1dec035b9593b48b9d3c
      a4c13d245d5f04169b0b1"""),
  ("auth2ack2_aes_secret",
   "80e8632c05fed6fc2a13b0f8d31a3cf645366239170ea067065aba8e28bac487"),
  ("auth2ack2_mac_secret",
   "2ea74ec5dae199227dff1af715362700e989d889d7a493cb0639691efb8e5f98"),
  ("auth2ack2_ingress_message", "foo"),
  ("auth2ack2_ingress_mac",
   "0c7ec6340062cc46f5e9f1e3cf86f8c8c403c5a0964f5df0ebd34a75ddc86db5")
]

let rng = newRng()

proc testE8Value(s: string): string =
  for item in eip8data:
    if item[0] == s:
      result = item[1]
      break

suite "Ethereum P2P handshake test suite":
  block:
    proc newTestHandshake(flags: set[HandshakeFlag]): Handshake =
      if Initiator in flags:
        let pk = PrivateKey.fromHex(testE8Value("initiator_private_key"))[]
        result = Handshake.init(rng[], pk.toKeyPair(), flags)

        let esec = testE8Value("initiator_ephemeral_private_key")
        result.ephemeral = PrivateKey.fromHex(esec)[].toKeyPair()
        let nonce = fromHex(stripSpaces(testE8Value("initiator_nonce")))
        result.initiatorNonce[0..^1] = nonce[0..^1]
      elif Responder in flags:
        let pk = PrivateKey.fromHex(testE8Value("receiver_private_key"))[]
        result = Handshake.init(rng[], pk.toKeyPair(), flags)

        let esec = testE8Value("receiver_ephemeral_private_key")
        result.ephemeral = PrivateKey.fromHex(esec)[].toKeyPair()
        let nonce = fromHex(stripSpaces(testE8Value("receiver_nonce")))
        result.responderNonce[0..^1] = nonce[0..^1]

    test "AUTH/ACK EIP-8 test vectors":
      var initiator = newTestHandshake({Initiator})
      var responder = newTestHandshake({Responder})
      var m0 = fromHex(stripSpaces(testE8Value("auth_ciphertext_eip8")))
      responder.decodeAuthMessage(m0).expect("decode success")
      check:
        responder.initiatorNonce[0..^1] == initiator.initiatorNonce[0..^1]
      let remoteEPubkey0 = initiator.ephemeral.pubkey
      check responder.remoteEPubkey == remoteEPubkey0
      let remoteHPubkey0 = initiator.host.pubkey
      check responder.remoteHPubkey == remoteHPubkey0
      var m1 = fromHex(stripSpaces(testE8Value("authack_ciphertext_eip8")))
      initiator.decodeAckMessage(m1).expect("decode success")
      let remoteEPubkey1 = responder.ephemeral.pubkey
      check:
        initiator.remoteEPubkey == remoteEPubkey1
        initiator.responderNonce[0..^1] == responder.responderNonce[0..^1]
      var taes = fromHex(stripSpaces(testE8Value("auth2ack2_aes_secret")))
      var tmac = fromHex(stripSpaces(testE8Value("auth2ack2_mac_secret")))

      var csecInitiator = initiator.getSecrets(m0, m1)
      var csecResponder = responder.getSecrets(m0, m1)
      check:
        csecInitiator.aesKey == csecResponder.aesKey
        csecInitiator.macKey == csecResponder.macKey
        taes[0..^1] == csecInitiator.aesKey[0..^1]
        tmac[0..^1] == csecInitiator.macKey[0..^1]

      var ingressMac = csecResponder.ingressMac
      ingressMac.update(testE8Value("auth2ack2_ingress_message"))
      check ingressMac.finish().data.toHex(true) ==
        testE8Value("auth2ack2_ingress_mac")

    test "AUTH/ACK EIP-8 with additional fields test vectors":
      var initiator = newTestHandshake({Initiator})
      var responder = newTestHandshake({Responder})
      var m0 = fromHex(stripSpaces(testE8Value("auth_ciphertext_eip8_3f")))
      responder.decodeAuthMessage(m0).expect("decode success")
      check:
        responder.initiatorNonce[0..^1] == initiator.initiatorNonce[0..^1]
      let remoteEPubkey0 = initiator.ephemeral.pubkey
      let remoteHPubkey0 = initiator.host.pubkey
      check:
        responder.remoteEPubkey == remoteEPubkey0
        responder.remoteHPubkey == remoteHPubkey0
      var m1 = fromHex(stripSpaces(testE8Value("authack_ciphertext_eip8_3f")))
      initiator.decodeAckMessage(m1).expect("decode success")
      let remoteEPubkey1 = responder.ephemeral.pubkey
      check:
        initiator.remoteEPubkey == remoteEPubkey1
        initiator.responderNonce[0..^1] == responder.responderNonce[0..^1]

    test "100 AUTH/ACK EIP-8 handshakes":
      for i in 1..100:
        var initiator = newTestHandshake({Initiator})
        var responder = newTestHandshake({Responder})
        var m0 = newSeq[byte](AuthMessageMaxEIP8)
        let k0 = initiator.authMessage(
          rng[], responder.host.pubkey, m0).expect("auth success")
        m0.setLen(k0)
        responder.decodeAuthMessage(m0).expect("decode success")

        var m1 = newSeq[byte](AckMessageMaxEIP8)
        let k1 = responder.ackMessage(rng[], m1).expect("ack success")
        m1.setLen(k1)
        initiator.decodeAckMessage(m1).expect("decode success")
        var csecInitiator = initiator.getSecrets(m0, m1)
        var csecResponder = responder.getSecrets(m0, m1)
        check:
          csecInitiator.aesKey == csecResponder.aesKey
          csecInitiator.macKey == csecResponder.macKey

    test "100 AUTH/ACK V4 handshakes":
      for i in 1..100:
        var initiator = newTestHandshake({Initiator})
        var responder = newTestHandshake({Responder})
        var m0 = newSeq[byte](AuthMessageMaxEIP8)
        let k0 = initiator.authMessage(
          rng[], responder.host.pubkey, m0).expect("auth success")
        m0.setLen(k0)
        responder.decodeAuthMessage(m0).expect("auth success")
        var m1 = newSeq[byte](AckMessageMaxEIP8)
        let k1 = responder.ackMessage(rng[], m1).expect("ack success")
        m1.setLen(k1)
        initiator.decodeAckMessage(m1).expect("ack success")

        var csecInitiator = initiator.getSecrets(m0, m1)
        var csecResponder = responder.getSecrets(m0, m1)
        check:
          csecInitiator.aesKey == csecResponder.aesKey
          csecInitiator.macKey == csecResponder.macKey

    test "Invalid AuthMessage - Minimum input size":
      var responder = newTestHandshake({Responder})

      # 1 byte short on minimum AuthMessage size
      var m = newSeq[byte](AuthMessageEIP8Length - 1)

      let res = responder.decodeAuthMessage(m)
      check:
        res.isErr()
        res.error == AuthError.IncompleteError

    test "Invalid AuthMessage - Minimum size prefix":
      var responder = newTestHandshake({Responder})

      # Minimum size for EIP8 AuthMessage
      var m = newSeq[byte](AuthMessageEIP8Length)
      # size prefix size of 281, 1 byte short
      m[0] = 1
      m[1] = 25

      let res = responder.decodeAuthMessage(m)
      check:
        res.isErr()
        res.error == AuthError.IncompleteError

    test "Invalid AuthMessage - Size prefix bigger than input":
      var responder = newTestHandshake({Responder})

      # Minimum size for EIP8 AuthMessage
      var m = newSeq[byte](AuthMessageEIP8Length)
      # size prefix size of 283, 1 byte too many
      m[0] = 1
      m[1] = 27

      let res = responder.decodeAuthMessage(m)
      check:
        res.isErr()
        res.error == AuthError.IncompleteError

    test "Invalid AckMessage - Minimum input size":
      var initiator = newTestHandshake({Initiator,})

      # 1 byte short on minimum size
      let m = newSeq[byte](AckMessageEIP8Length - 1)

      let res = initiator.decodeAckMessage(m)
      check:
        res.isErr()
        res.error == AuthError.IncompleteError

    test "Invalid AckMessage - Minimum size prefix":
      var initiator = newTestHandshake({Initiator})

      # Minimum size for EIP8 AckMessage
      var m = newSeq[byte](AckMessageEIP8Length)
      # size prefix size of 214, 1 byte short
      m[0] = 0
      m[1] = 214

      let res = initiator.decodeAckMessage(m)
      check:
        res.isErr()
        res.error == AuthError.IncompleteError

    test "Invalid AckMessage - Size prefix bigger than input":
      var initiator = newTestHandshake({Initiator})

      # Minimum size for EIP8 AckMessage
      var m = newSeq[byte](AckMessageEIP8Length)
      # size prefix size of 216, 1 byte too many
      m[0] = 0
      m[1] = 216

      let res = initiator.decodeAckMessage(m)
      check:
        res.isErr()
        res.error == AuthError.IncompleteError
