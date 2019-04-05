import
  unittest, strformat, options, json_rpc/[rpcserver, rpcclient],
  eth/common as eth_common, eth/p2p as eth_p2p,
  eth/[rlp, keys], eth/p2p/rlpx_protocols/whisper_protocol,
  ../nimbus/rpc/[common, hexstrings, rpc_types, whisper], ../nimbus/config

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

## Generate client convenience marshalling wrappers from forward declarations
## For testing, ethcallsigs needs to be kept in sync with ../nimbus/rpc/[common, p2p]
const sigPath = &"{sourceDir}{DirSep}rpcclient{DirSep}ethcallsigs.nim"
createRpcSigs(RpcSocketClient, sigPath)

proc setupEthNode: EthereumNode =
  var
    conf = getConfiguration()
    keypair: KeyPair
  keypair.seckey = conf.net.nodekey
  keypair.pubkey = conf.net.nodekey.getPublicKey()

  var srvAddress: Address
  srvAddress.ip = parseIpAddress("0.0.0.0")
  srvAddress.tcpPort = Port(conf.net.bindPort)
  srvAddress.udpPort = Port(conf.net.discPort)
  result = newEthereumNode(keypair, srvAddress, conf.net.networkId,
                              nil, "nimbus 0.1.0", addAllCapabilities = false)
  result.addCapability Whisper

proc doTests =
  var ethNode = setupEthNode()

  # Create Ethereum RPCs
  let RPC_PORT = 8545
  var
    rpcServer = newRpcSocketServer(["localhost:" & $RPC_PORT])
    client = newRpcSocketClient()
  let keys = newWhisperKeys()
  setupCommonRPC(rpcServer)
  setupWhisperRPC(ethNode, keys, rpcServer)

  # Begin tests
  rpcServer.start()
  waitFor client.connect("localhost", Port(RPC_PORT))

  suite "Whisper Remote Procedure Calls":
    test "shh_version":
      check waitFor(client.shh_version()) == whisperVersionStr
    test "shh_info":
      let info = waitFor client.shh_info()
      check info.maxMessageSize == defaultMaxMsgSize
    test "shh_setMaxMessageSize":
      let testValue = 1024'u64
      check waitFor(client.shh_setMaxMessageSize(testValue)) == true
      var info = waitFor client.shh_info()
      check info.maxMessageSize == testValue
      check waitFor(client.shh_setMaxMessageSize(defaultMaxMsgSize + 1)) == false
      info = waitFor client.shh_info()
      check info.maxMessageSize == testValue
    test "shh_setMinPoW":
      let testValue = 0.0001
      check waitFor(client.shh_setMinPoW(testValue)) == true
      let info = waitFor client.shh_info()
      check info.minPow == testValue
    # test "shh_markTrustedPeer":
      # TODO: need to connect a peer to test
    test "shh asymKey tests":
      let keyID = waitFor client.shh_newKeyPair()
      check:
        waitFor(client.shh_hasKeyPair(keyID)) == true
        waitFor(client.shh_deleteKeyPair(keyID)) == true
        waitFor(client.shh_hasKeyPair(keyID)) == false
        waitFor(client.shh_deleteKeyPair(keyID)) == false

      let privkey = "0x5dc5381cae54ba3174dc0d46040fe11614d0cc94d41185922585198b4fcef9d3"
      let pubkey = "0x04e5fd642a0f630bbb1e4cd7df629d7b8b019457a9a74f983c0484a045cebb176def86a54185b50bbba6bbf97779173695e92835d63109c23471e6da382f922fdb"
      let keyID2 = waitFor client.shh_addPrivateKey(privkey)
      check:
        waitFor(client.shh_getPublicKey(keyID2)).string == pubkey
        waitFor(client.shh_getPrivateKey(keyID2)).string == privkey
        waitFor(client.shh_hasKeyPair(keyID2)) == true
        waitFor(client.shh_deleteKeyPair(keyID2)) == true
        waitFor(client.shh_hasKeyPair(keyID2)) == false
        waitFor(client.shh_deleteKeyPair(keyID2)) == false
    test "shh symKey tests":
      let keyID = waitFor client.shh_newSymKey()
      check:
        waitFor(client.shh_hasSymKey(keyID)) == true
        waitFor(client.shh_deleteSymKey(keyID)) == true
        waitFor(client.shh_hasSymKey(keyID)) == false
        waitFor(client.shh_deleteSymKey(keyID)) == false

      let symKey = "0x0000000000000000000000000000000000000000000000000000000000000001"
      let keyID2 = waitFor client.shh_addSymKey(symKey)
      check:
        waitFor(client.shh_getSymKey(keyID2)).string == symKey
        waitFor(client.shh_hasSymKey(keyID2)) == true
        waitFor(client.shh_deleteSymKey(keyID2)) == true
        waitFor(client.shh_hasSymKey(keyID2)) == false
        waitFor(client.shh_deleteSymKey(keyID2)) == false

      let keyID3 = waitFor client.shh_generateSymKeyFromPassword("password")
      let keyID4 = waitFor client.shh_generateSymKeyFromPassword("password")
      let keyID5 = waitFor client.shh_generateSymKeyFromPassword("nimbus!")
      check:
        waitFor(client.shh_getSymKey(keyID3)).string ==
          waitFor(client.shh_getSymKey(keyID4)).string
        waitFor(client.shh_getSymKey(keyID3)).string !=
          waitFor(client.shh_getSymKey(keyID5)).string
        waitFor(client.shh_hasSymKey(keyID3)) == true
        waitFor(client.shh_deleteSymKey(keyID3)) == true
        waitFor(client.shh_hasSymKey(keyID3)) == false
        waitFor(client.shh_deleteSymKey(keyID3)) == false

    test "shh symKey post and filter":
      var options: WhisperFilterOptions
      options.symKeyID = some(waitFor client.shh_newSymKey())
      options.topics = some(@["0x12345678".TopicStr])
      let filterID = waitFor client.shh_newMessageFilter(options)

      var message: WhisperPostMessage
      message.symKeyID = options.symKeyID
      message.ttl = 30
      message.topic = some("0x12345678".TopicStr)
      message.payload = "0x45879632".HexDataStr
      message.powTime = 1.0
      message.powTarget = 0.001
      check:
        waitFor(client.shh_post(message)) == true
      # TODO: this does not work due to overloads?
      # var messages = waitFor client.shh_getFilterMessages(filterID)

    test "shh asymKey post and filter":
      var options: WhisperFilterOptions
      let keyID = waitFor client.shh_newKeyPair()
      options.privateKeyID = some(keyID)
      let filterID = waitFor client.shh_newMessageFilter(options)

      var message: WhisperPostMessage
      message.pubKey = some(waitFor(client.shh_getPublicKey(keyID)))
      message.ttl = 30
      message.topic = some("0x12345678".TopicStr)
      message.payload = "0x45879632".HexDataStr
      message.powTime = 1.0
      message.powTarget = 0.001
      check:
        waitFor(client.shh_post(message)) == true
      # TODO: this does not work due to overloads?
      # var messages = waitFor client.shh_getFilterMessages(filterID)

  rpcServer.stop()
  rpcServer.close()

doTests()
