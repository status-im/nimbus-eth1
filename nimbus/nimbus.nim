# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  os, strutils, net, options,
  eth/keys, db/[storage_types, db_chain, select_backend],
  eth/common as eth_common, eth/p2p as eth_p2p,
  chronos, json_rpc/rpcserver, chronicles,
  eth/p2p/rlpx_protocols/[eth_protocol, les_protocol],
  eth/p2p/blockchain_sync, eth/net/nat,
  config, genesis, rpc/[common, p2p, debug, whisper], p2p/chain,
  eth/trie/db

## TODO:
## * No IPv6 support
## * No multiple bind addresses support
## * No database support

const
  nimbusClientId = "nimbus 0.1.0"

when not defined(windows):
  from posix import SIGINT, SIGTERM

type
  NimbusState = enum
    Starting, Running, Stopping, Stopped

  NimbusObject = ref object
    rpcServer*: RpcHttpServer
    ethNode*: EthereumNode
    state*: NimbusState

proc start(): NimbusObject =
  var nimbus = NimbusObject()
  var conf = getConfiguration()

  setLogLevel(conf.debug.logLevel)
  if len(conf.debug.logFile) != 0:
    discard defaultChroniclesStream.output.open(conf.debug.logFile, fmAppend)

  ## Creating RPC Server
  if RpcFlags.Enabled in conf.rpc.flags:
    nimbus.rpcServer = newRpcHttpServer(conf.rpc.binds)
    setupCommonRpc(nimbus.rpcServer)

  ## Creating P2P Server
  if conf.net.nodekey.isZeroKey():
    conf.net.nodekey = newPrivateKey()

  var keypair: KeyPair
  keypair.seckey = conf.net.nodekey
  keypair.pubkey = conf.net.nodekey.getPublicKey()

  var address: Address
  address.ip = parseIpAddress("0.0.0.0")
  address.tcpPort = Port(conf.net.bindPort)
  address.udpPort = Port(conf.net.discPort)
  if conf.net.nat == NatNone:
    if conf.net.externalIP != "":
      # any required port redirection is assumed to be done by hand
      address.ip = parseIpAddress(conf.net.externalIP)
  else:
    # automated NAT traversal
    let extIP = getExternalIP(conf.net.nat)
    # This external IP only appears in the logs, so don't worry about dynamic
    # IPs. Don't remove it either, because the above call does initialisation
    # and discovery for NAT-related objects.
    if extIP.isSome:
      address.ip = extIP.get()
      let extPorts = redirectPorts(tcpPort = address.tcpPort,
                                    udpPort = address.udpPort,
                                    description = NIMBUS_NAME & " " & NIMBUS_VERSION)
      if extPorts.isSome:
        (address.tcpPort, address.udpPort) = extPorts.get()

  createDir(conf.dataDir)
  let trieDB = trieDB newChainDb(conf.dataDir)
  let chainDB = newBaseChainDB(trieDB,
    conf.prune == PruneMode.Full,
    conf.net.networkId.toPublicNetwork())

  if canonicalHeadHashKey().toOpenArray notin trieDB:
    initializeEmptyDb(chainDb)
    doAssert(canonicalHeadHashKey().toOpenArray in trieDB)

  nimbus.ethNode = newEthereumNode(keypair, address, conf.net.networkId,
                                   nil, nimbusClientId)

  nimbus.ethNode.chain = newChain(chainDB)

  if RpcFlags.Eth in conf.rpc.flags:
    setupEthRpc(nimbus.ethNode, chainDB, nimbus.rpcServer)

  if RpcFlags.Shh in conf.rpc.flags:
    setupWhisperRPC(nimbus.rpcServer)

  if RpcFlags.Debug in conf.rpc.flags:
    setupDebugRpc(chainDB, nimbus.rpcServer)

  ## Starting servers
  nimbus.state = Starting
  if RpcFlags.Enabled in conf.rpc.flags:
    nimbus.rpcServer.rpc("admin_quit") do() -> string:
      nimbus.state = Stopping
      result = "EXITING"
    nimbus.rpcServer.start()

  waitFor nimbus.ethNode.connectToNetwork(conf.net.bootNodes,
    enableDiscovery = NoDiscover notin conf.net.flags)

  # TODO: temp code until the CLI/RPC interface is fleshed out
  let status = waitFor nimbus.ethNode.fastBlockchainSync()
  if status != syncSuccess:
    debug "Block sync failed: ", status

  nimbus.state = Running
  result = nimbus

proc stop*(nimbus: NimbusObject) {.async.} =
  trace "Graceful shutdown"
  nimbus.rpcServer.stop()

proc process*(nimbus: NimbusObject) =
  if nimbus.state == Running:
    when not defined(windows):
      proc signalBreak(udata: pointer) =
        nimbus.state = Stopping
      # Adding SIGINT, SIGTERM handlers
      # discard addSignal(SIGINT, signalBreak)
      # discard addSignal(SIGTERM, signalBreak)

    # Main loop
    while nimbus.state == Running:
      poll()

    # Stop loop
    waitFor nimbus.stop()

when isMainModule:
  var message: string

  ## Pring Nimbus header
  echo NimbusHeader

  ## show logs on stdout until we get the user's logging choice
  discard defaultChroniclesStream.output.open(stdout)

  ## Processing command line arguments
  if processArguments(message) != ConfigStatus.Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  var nimbus = start()
  nimbus.process()
