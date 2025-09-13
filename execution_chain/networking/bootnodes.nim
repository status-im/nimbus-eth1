# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[strutils, os],
  stew/[io2, base64],
  eth/p2p/discoveryv5/enr,
  ./discoveryv4/enode

type
  BootstrapNodes* = object
    enrs*: seq[enr.Record]
    enodes*: seq[ENode]

#------------------------------------------------------------------------------
# BootstrapNodes constants
#------------------------------------------------------------------------------

func removeCommentAndSpaces(line: string, start = 0): string =
  const alphabet = B64UrlAlphabet
  var pos = -1
  for i in start..<line.len:
    let c = line[i]
    if c.int > alphabet.decode.high:
      pos = i
      break
    if c in {':', '/', '@', '.'}:
      # URI chars
      continue
    if alphabet.decode[c.int] == -1:
      pos = i
      break

  if pos > 0:
    line.substr(start, pos - 1)
  else:
    line.substr(start)

func bootNodeFile(network: string): (string, string) {.compileTime.} =
  const
    vendorPath = currentSourcePath.rsplit({os.DirSep, os.AltSep}, 3)[0] & "/vendor/nimbus-eth2/vendor/"
    bootNodeYaml = "/metadata/bootstrap_nodes.yaml"
    enodesYaml = "/metadata/enodes.yaml"

  (vendorPath & network & bootNodeYaml, vendorPath & network & enodesYaml)

func countLines(enrsText, enodesText: string): int {.compileTime.} =
  for line in splitLines(enrsText):
    if line.startsWith("- enr:") or
       line.startsWith("enr:"):
      inc result

  for line in splitLines(enodesText):
    if line.startsWith("- enode:") or
       line.startsWith("enode:"):
      inc result

func bootData(numLines: static[int], enrsText, enodesText: string): array[numLines, string] {.compileTime.} =
  var i = 0
  for line in splitLines(enrsText):
    if line.startsWith("- enr:"):
      result[i] = line.substr(2)
      inc i

    if line.startsWith("enr:"): 
      result[i] = line
      inc i
  
  for line in splitLines(enodesText):
    if line.startsWith("- enode:"):
      result[i] = line.substr(2)
      inc i

    if line.startsWith("enode:"):
      result[i] = line
      inc i

template loadBootstrapNodes(name: static[string]): auto =
  block one:
    const
      (enrs, enodes) = bootNodeFile(name)
      enrsText = staticRead(enrs) 
      enodesText = staticRead(enodes)
      numLines = countLines(enrsText, enodesText)
    bootData(numLines, enrsText, enodesText)

const
  mainnet = loadBootstrapNodes("mainnet")
  holesky = loadBootstrapNodes("holesky")
  sepolia = loadBootstrapNodes("sepolia")
  hoodi = loadBootstrapNodes("hoodi")

#------------------------------------------------------------------------------
# Private helpers
#------------------------------------------------------------------------------

func appendBootstrapNode(line: string, boot: var BootstrapNodes): Result[bool, string] =
  if line.startsWith("enr:"):
    var rec = fromURI(enr.Record, line.removeCommentAndSpaces).valueOr:
      return err(line & ": " & $error)
    boot.enrs.add move(rec)
    return ok(true)

  if line.startsWith("enode:"):
    var enode = ENode.fromString(line.removeCommentAndSpaces).valueOr:
      return err(line & ": " & $error)
    boot.enodes.add move(enode)
    return ok(true)

  if line.startsWith("- enr:"):
    var rec = fromURI(enr.Record, line.removeCommentAndSpaces(2)).valueOr:
      return err(line & ": " & $error)
    boot.enrs.add move(rec)
    return ok(true)

  if line.startsWith("- enode:"):
    var enode = ENode.fromString(line.removeCommentAndSpaces(2)).valueOr:
      return err(line & ": " & $error)
    boot.enodes.add move(enode)
    return ok(true)

  ok(false)

func appendBootstrapNodes(list: openArray[string], boot: var BootstrapNodes): Result[void, string] =
  for line in list:
    discard ? appendBootstrapNode(line, boot)

  ok()

#------------------------------------------------------------------------------
# Public functions
#------------------------------------------------------------------------------

func getBootstrapNodes*(name: string, boot: var BootstrapNodes): Result[void, string] =
  case name:
  of "mainnet": appendBootstrapNodes(mainnet, boot)
  of "holesky": appendBootstrapNodes(holesky, boot)
  of "sepolia": appendBootstrapNodes(sepolia, boot)
  of "hoodi":   appendBootstrapNodes(hoodi, boot)
  else: err("network not supported: " & name)

proc loadBootstrapNodes*(fileName: string, boot: var BootstrapNodes): Result[void, string] =
  ## Load bootnodes from file
  let text = io2.readAllChars(fileName).valueOr:
    return err($error)

  for line in splitLines(text):
    discard ? appendBootstrapNode(line, boot)

  ok()

proc parseBootstrapNodes*(list: openArray[string], boot: var BootstrapNodes): Result[void, string] =
  ## Parse bootnodes from CLI
  for line in list:
    discard ? appendBootstrapNode(line, boot)

  ok()

func len*(boot: BootstrapNodes): int =
  boot.enrs.len + boot.enodes.len
