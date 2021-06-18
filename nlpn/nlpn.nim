# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  confutils, confutils/std/net, chronicles, chronicles/topics_registry,
  chronos, metrics, metrics/chronos_httpserver, json_rpc/servers/httpserver,
  eth/keys, eth/net/nat,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/portal/protocol as portal_protocol,
  ./conf, ./rpc/eth_api

proc run(config: PortalConf) {.raises: [CatchableError, Defect].} =
  let
    rng = newRng()
    bindIp = config.listenAddress
    udpPort = Port(config.udpPort)
    # TODO: allow for no TCP port mapping!
    (extIp, _, extUdpPort) =
      try: setupAddress(config.nat,
        config.listenAddress, udpPort, udpPort, "dcli")
      except CatchableError as exc: raise exc
      # TODO: Ideally we don't have the Exception here
      except Exception as exc: raiseAssert exc.msg

  let d = newProtocol(config.nodeKey,
          extIp, none(Port), extUdpPort,
          bootstrapRecords = config.bootnodes,
          bindIp = bindIp, bindPort = udpPort,
          enrAutoUpdate = config.enrAutoUpdate,
          rng = rng)

  d.open()

  let portal = PortalProtocol.new(d)

  if config.metricsEnabled:
    let
      address = config.metricsAddress
      port = config.metricsPort
    notice "Starting metrics HTTP server",
      url = "http://" & $address & ":" & $port & "/metrics"
    try:
      chronos_httpserver.startMetricsHttpServer($address, port)
    except CatchableError as exc: raise exc
    # TODO: Ideally we don't have the Exception here
    except Exception as exc: raiseAssert exc.msg

  if config.rpcEnabled:
    let
      ta = initTAddress(config.rpcAddress, config.rpcPort)
      rpcHttpServer = newRpcHttpServer([ta])
    rpcHttpServer.installEthApiHandlers()
    rpcHttpServer.start()

  d.start()

  runForever()

when isMainModule:
  {.pop.}
  let config = PortalConf.load()
  {.push raises: [Defect].}

  setLogLevel(config.logLevel)

  case config.cmd
  of noCommand: run(config)
