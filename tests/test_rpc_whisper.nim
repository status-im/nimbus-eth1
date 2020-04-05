import
  unittest, strformat, options, stew/byteutils, json_rpc/[rpcserver, rpcclient],
  eth/common as eth_common, eth/[rlp, keys],
  eth/p2p/rlpx_protocols/whisper_protocol,
  ../nimbus/rpc/[common, hexstrings, rpc_types, whisper, key_storage],
  ./test_helpers

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

## Generate client convenience marshalling wrappers from forward declarations
## For testing, ethcallsigs needs to be kept in sync with ../nimbus/rpc/[common, p2p]
const sigPath = &"{sourceDir}{DirSep}rpcclient{DirSep}ethcallsigs.nim"
createRpcSigs(RpcSocketClient, sigPath)

proc doTests {.async.} =
  var ethNode = setupEthNode(Whisper)

  # Create Ethereum RPCs
  let RPC_PORT = 8545
  var
    rpcServer = newRpcSocketServer(["localhost:" & $RPC_PORT])
    client = newRpcSocketClient()
  let keys = newKeyStorage()
  setupWhisperRPC(ethNode, keys, rpcServer)

  # Begin tests
  rpcServer.start()
  await client.connect("localhost", Port(RPC_PORT))

  suite "Whisper Remote Procedure Calls":
    test "shh_version":
      check await(client.shh_version()) == whisperVersionStr
    test "shh_info":
      let info = await client.shh_info()
      check info.maxMessageSize == defaultMaxMsgSize
    test "shh_setMaxMessageSize":
      let testValue = 1024'u64
      check await(client.shh_setMaxMessageSize(testValue)) == true
      var info = await client.shh_info()
      check info.maxMessageSize == testValue
      expect ValueError:
        discard await(client.shh_setMaxMessageSize(defaultMaxMsgSize + 1))
      info = await client.shh_info()
      check info.maxMessageSize == testValue
    test "shh_setMinPoW":
      let testValue = 0.0001
      check await(client.shh_setMinPoW(testValue)) == true
      let info = await client.shh_info()
      check info.minPow == testValue
    # test "shh_markTrustedPeer":
      # TODO: need to connect a peer to test
    test "shh asymKey tests":
      let keyID = await client.shh_newKeyPair()
      check:
        await(client.shh_hasKeyPair(keyID)) == true
        await(client.shh_deleteKeyPair(keyID)) == true
        await(client.shh_hasKeyPair(keyID)) == false
      expect ValueError:
        discard await(client.shh_deleteKeyPair(keyID))

      let privkey = "0x5dc5381cae54ba3174dc0d46040fe11614d0cc94d41185922585198b4fcef9d3"
      let pubkey = "0x04e5fd642a0f630bbb1e4cd7df629d7b8b019457a9a74f983c0484a045cebb176def86a54185b50bbba6bbf97779173695e92835d63109c23471e6da382f922fdb"
      let keyID2 = await client.shh_addPrivateKey(privkey)
      check:
        await(client.shh_getPublicKey(keyID2)) == pubkey.toPublicKey
        await(client.shh_getPrivateKey(keyID2)).toRaw() == privkey.toPrivateKey.toRaw()
        await(client.shh_hasKeyPair(keyID2)) == true
        await(client.shh_deleteKeyPair(keyID2)) == true
        await(client.shh_hasKeyPair(keyID2)) == false
      expect ValueError:
        discard await(client.shh_deleteKeyPair(keyID2))
    test "shh symKey tests":
      let keyID = await client.shh_newSymKey()
      check:
        await(client.shh_hasSymKey(keyID)) == true
        await(client.shh_deleteSymKey(keyID)) == true
        await(client.shh_hasSymKey(keyID)) == false
      expect ValueError:
        discard await(client.shh_deleteSymKey(keyID))

      let symKey = "0x0000000000000000000000000000000000000000000000000000000000000001"
      let keyID2 = await client.shh_addSymKey(symKey)
      check:
        await(client.shh_getSymKey(keyID2)) == symKey.toSymKey
        await(client.shh_hasSymKey(keyID2)) == true
        await(client.shh_deleteSymKey(keyID2)) == true
        await(client.shh_hasSymKey(keyID2)) == false
      expect ValueError:
        discard await(client.shh_deleteSymKey(keyID2))

      let keyID3 = await client.shh_generateSymKeyFromPassword("password")
      let keyID4 = await client.shh_generateSymKeyFromPassword("password")
      let keyID5 = await client.shh_generateSymKeyFromPassword("nimbus!")
      check:
        await(client.shh_getSymKey(keyID3)) ==
          await(client.shh_getSymKey(keyID4))
        await(client.shh_getSymKey(keyID3)) !=
          await(client.shh_getSymKey(keyID5))
        await(client.shh_hasSymKey(keyID3)) == true
        await(client.shh_deleteSymKey(keyID3)) == true
        await(client.shh_hasSymKey(keyID3)) == false
      expect ValueError:
        discard await(client.shh_deleteSymKey(keyID3))

    # Some defaults for the filter & post tests
    let
      ttl = 30'u64
      topicStr = "0x12345678"
      payload = "0x45879632"
      # A very low target and long time so we are sure the test never fails
      # because of this
      powTarget = 0.001
      powTime = 1.0

    test "shh filter create and delete":
      let
        topic = topicStr.toTopic()
        symKeyID = await client.shh_newSymKey()
        options = WhisperFilterOptions(symKeyID: some(symKeyID),
                                       topics: some(@[topic]))
        filterID = await client.shh_newMessageFilter(options)

      check:
        filterID.string.isValidIdentifier
        await(client.shh_deleteMessageFilter(filterID)) == true
      expect ValueError:
        discard await(client.shh_deleteMessageFilter(filterID))

    test "shh symKey post and filter loop":
      let
        topic = topicStr.toTopic()
        symKeyID = await client.shh_newSymKey()
        options = WhisperFilterOptions(symKeyID: some(symKeyID),
                                       topics: some(@[topic]))
        filterID = await client.shh_newMessageFilter(options)
        message = WhisperPostMessage(symKeyID: some(symKeyID),
                                     ttl: ttl,
                                     topic: some(topic),
                                     payload: payload.HexDataStr,
                                     powTime: powTime,
                                     powTarget: powTarget)
      check:
        await(client.shh_setMinPoW(powTarget)) == true
        await(client.shh_post(message)) == true

      let messages = await client.shh_getFilterMessages(filterID)
      check:
        messages.len == 1
        messages[0].sig.isNone()
        messages[0].recipientPublicKey.isNone()
        messages[0].ttl == ttl
        messages[0].topic == topic
        messages[0].payload == hexToSeqByte(payload)
        messages[0].padding.len > 0
        messages[0].pow >= powTarget

        await(client.shh_deleteMessageFilter(filterID)) == true

    test "shh asymKey post and filter loop":
      let
        topic = topicStr.toTopic()
        privateKeyID = await client.shh_newKeyPair()
        options = WhisperFilterOptions(privateKeyID: some(privateKeyID))
        filterID = await client.shh_newMessageFilter(options)
        pubKey = await client.shh_getPublicKey(privateKeyID)
        message = WhisperPostMessage(pubKey: some(pubKey),
                                     ttl: ttl,
                                     topic: some(topic),
                                     payload: payload.HexDataStr,
                                     powTime: powTime,
                                     powTarget: powTarget)
      check:
        await(client.shh_setMinPoW(powTarget)) == true
        await(client.shh_post(message)) == true

      let messages = await client.shh_getFilterMessages(filterID)
      check:
        messages.len == 1
        messages[0].sig.isNone()
        messages[0].recipientPublicKey.get() == pubKey
        messages[0].ttl == ttl
        messages[0].topic == topic
        messages[0].payload == hexToSeqByte(payload)
        messages[0].padding.len > 0
        messages[0].pow >= powTarget

        await(client.shh_deleteMessageFilter(filterID)) == true

    test "shh signature in post and filter loop":
      let
        topic = topicStr.toTopic()
        symKeyID = await client.shh_newSymKey()
        privateKeyID = await client.shh_newKeyPair()
        pubKey = await client.shh_getPublicKey(privateKeyID)
        options = WhisperFilterOptions(symKeyID: some(symKeyID),
                                       topics: some(@[topic]),
                                       sig: some(pubKey))
        filterID = await client.shh_newMessageFilter(options)
        message = WhisperPostMessage(symKeyID: some(symKeyID),
                                     sig: some(privateKeyID),
                                     ttl: ttl,
                                     topic: some(topic),
                                     payload: payload.HexDataStr,
                                     powTime: powTime,
                                     powTarget: powTarget)
      check:
        await(client.shh_setMinPoW(powTarget)) == true
        await(client.shh_post(message)) == true

      let messages = await client.shh_getFilterMessages(filterID)
      check:
        messages.len == 1
        messages[0].sig.get() == pubKey
        messages[0].recipientPublicKey.isNone()
        messages[0].ttl == ttl
        messages[0].topic == topic
        messages[0].payload == hexToSeqByte(payload)
        messages[0].padding.len > 0
        messages[0].pow >= powTarget

        await(client.shh_deleteMessageFilter(filterID)) == true

  rpcServer.stop()
  rpcServer.close()

waitFor doTests()
