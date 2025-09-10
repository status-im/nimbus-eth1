# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
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
  Bootnodes* = object
    enrs*: seq[enr.Record]
    enodes*: seq[ENode]

#------------------------------------------------------------------------------
# Bootnodes constants
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

func countLines(text: string): int {.compileTime.} =
  for line in splitLines(text):
    if line.startsWith("- enr:") or
       line.startsWith("- enode:") or
       line.startsWith("enr:") or
       line.startsWith("enode:"):
      inc result

func bootData(numLines: static[int], text: string): array[numLines, string] {.compileTime.} =
  var i = 0
  for line in splitLines(text):
    if line.startsWith("- enr:") or
       line.startsWith("- enode:"):
      result[i] = line.substr(2)
      inc i

    if line.startsWith("enr:") or
       line.startsWith("enode:"):
      result[i] = line
      inc i

template loadBootNodes(name: static[string]): auto =
  block one:
    const
      (enrs, enodes) = bootNodeFile(name)
      text = staticRead(enrs) & "\n" & staticRead(enodes)
      numLines = countLines(text)
    bootData(numLines, text)

const
  mainnet = loadBootNodes("mainnet")
  holesky = loadBootNodes("holesky")
  sepolia = loadBootNodes("sepolia")
  hoodi = loadBootNodes("hoodi")

#------------------------------------------------------------------------------
# Private helpers
#------------------------------------------------------------------------------

func appendBootnode(line: string, boot: var Bootnodes): Result[bool, string] =
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
      debugEcho line.removeCommentAndSpaces(2).len
      return err(line & ": " & $error)
    boot.enrs.add move(rec)
    return ok(true)

  if line.startsWith("- enode:"):
    var enode = ENode.fromString(line.removeCommentAndSpaces(2)).valueOr:
      return err(line & ": " & $error)
    boot.enodes.add move(enode)
    return ok(true)

  ok(false)

func appendBootnodes(list: openArray[string], boot: var Bootnodes): Result[void, string] =
  for line in list:
    discard ? appendBootnode(line, boot)

  ok()

#------------------------------------------------------------------------------
# Public functions
#------------------------------------------------------------------------------

func getBootnodes*(name: string, boot: var Bootnodes): Result[void, string] =
  case name:
  of "mainnet": appendBootnodes(mainnet, boot)
  of "holesky": appendBootnodes(holesky, boot)
  of "sepolia": appendBootnodes(sepolia, boot)
  of "hoodi":   appendBootnodes(hoodi, boot)
  else: err("network not supported: " & name)

proc loadBootnodes*(fileName: string, boot: var Bootnodes): Result[void, string] =
  ## Load bootnodes from file
  let text = io2.readAllChars(fileName).valueOr:
    return err($error)

  for line in splitLines(text):
    discard ? appendBootnode(line, boot)

  ok()

proc parseBootnodes*(list: openArray[string], boot: var Bootnodes): Result[void, string] =
  ## Parse bootnodes from CLI
  for line in list:
    let parsed = ? appendBootnode(line, boot)
    if parsed:
      continue
    if line.startsWith('#'):
      continue
    if line.len == 0:
      continue
    if not fileExists(line):
      return err("Cannot parse " & line & " into bootnode")
    ? loadBootnodes(line, boot)

  ok()

func len*(boot: Bootnodes): int =
  boot.enrs.len + boot.enodes.len
