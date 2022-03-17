# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[sequtils, strutils, os, macros]

proc loadBootstrapNodes(
    path: string): seq[string] {.raises: [IOError, Defect].} =
  # Read a list of ENR URIs from a file containing a flat list of entries.
  # If the file can't be read, this will raise. This is intentionally.
  splitLines(readFile(path)).
    filterIt(it.startsWith("enr:")).
      mapIt(it.strip())

proc loadCompileTimeBootstrapNodes(
    path: string): seq[string] {.raises: [Defect].} =
  try:
    return loadBootstrapNodes(path)
  # TODO: This error doesn't seem to get printed. It instead dies with an
  # unhandled exception (IOError)
  except IOError as err:
    macros.error "Failed to load bootstrap nodes metadata at '" &
      path & "': " & err.msg

const
  # TODO: Change this from our local repo to an eth-client repo if/when this
  # gets created for the Portal networks.
  portalNetworksDir =
    currentSourcePath.parentDir.replace('\\', '/') / "network_data"
  # Note:
  # For now it gets called testnet0 but this Portal network serves Eth1 mainnet
  # data. Giving the actual Portal (test)networks different names might not be
  # that useful as there is no way to distinguish the networks currently.
  # Additionally, sub-networks like history network pass the eth1 network
  # information in their requests, potentially supporting many eth1 networks
  # over a single Portal Network.
  #
  # When more config data is required per Portal network, a metadata object can
  # be created, but right now only bootstrap nodes can be different.
  # TODO: It would be nice to be able to use `loadBootstrapFile` here, but that
  # doesn't work at compile time. The main issue seems to be the usage of
  # rlp.rawData() in the enr code.
  testnet0BootstrapNodes* = loadCompileTimeBootstrapNodes(
    portalNetworksDir / "testnet0" / "bootstrap_nodes.txt")
