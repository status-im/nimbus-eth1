# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import asyncdispatch, net           # stdlib modules
import ethp2p, eth_keys, nimcrypto  # external modules
import service, ../config           # internal modules

type
  Discovery4Service* = object of NetworkService
    address: Address
    dproto: DiscoveryProtocol
    bootnodes: seq[ENode]

proc init*(s: var Discovery4Service): ServiceStatus =
  s.id = "Nimbus.Discovery.4"
  s.flags = {}
  s.state = Stopped
  s.error = ""
  result = ServiceStatus.Success

proc configure*(s: var Discovery4Service): ServiceStatus =
  let conf = getConfiguration()
  cleanError(s)
  checkState(s, {Stopped, Paused})

  var bootnodes = newSeq[ENode]()
  if TestNet in conf.net.flags:
    for item in ROPSTEN_BOOTNODES:
      bootnodes.add(initENode(item))
  elif MainNet in conf.net.flags:
    for item in MAINNET_BOOTNODES:
      bootnodes.add(initENode(item))
  
  for item in conf.net.bootNodes:
    bootnodes.add(item)
  for item in conf.net.bootNodes4:
    bootnodes.add(item)

  if isFullZero(conf.net.nodeKey):
    s.setFailure("P2P Node private key is not set!")
    return ServiceStatus.Error

  if Configured notin s.flags:
    s.address.ip = parseIpAddress("0.0.0.0")
    s.address.tcpPort = Port(conf.net.bindPort)
    s.address.udpPort = Port(conf.net.discPort)
    s.dproto = newDiscoveryProtocol(conf.net.nodeKey, s.address, bootnodes)

  s.flags.incl(Configured)
  result = ServiceStatus.Success

proc start*(s: var Discovery4Service): ServiceStatus =
  cleanError(s)
  checkState(s, {Stopped})
  checkFlags(s, {Configured}, "not configured!")
  try:
    s.dproto.open()
    waitFor s.dproto.bootstrap()
  except ValueError as e:
    s.setFailure(e.msg)
    result = ServiceStatus.Error
  except OSError as e:
    s.setFailure(e.msg)
    result = ServiceStatus.Error
  result = ServiceStatus.Success

proc stop*(s: var Discovery4Service): ServiceStatus =
  cleanError(s)
  checkState(s, {Running, Paused})
  checkFlags(s, {Configured}, "not configured!")
  result = ServiceStatus.Success

proc pause*(s: var Discovery4Service): ServiceStatus =
  cleanError(s)
  checkState(s, {Running})
  s.state = Paused
  result = ServiceStatus.Success

proc resume*(s: var Discovery4Service): ServiceStatus =
  cleanError(s)
  checkState(s, {Paused})
  result = ServiceStatus.Success
