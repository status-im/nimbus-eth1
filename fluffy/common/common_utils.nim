# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[os, strutils],
  chronicles,
  eth/p2p/discoveryv5/enr

iterator strippedLines(filename: string): string {.raises: [ref IOError].} =
  for line in lines(filename):
    let stripped = strip(line)
    if stripped.startsWith('#'): # Comments
      continue

    if stripped.len > 0:
      yield stripped

proc addBootstrapNode(bootstrapAddr: string,
                       bootstrapEnrs: var seq[Record]) =
  var enrRec: enr.Record
  if enrRec.fromURI(bootstrapAddr):
    bootstrapEnrs.add enrRec
  else:
    warn "Ignoring invalid bootstrap ENR", bootstrapAddr

proc loadBootstrapFile*(bootstrapFile: string,
                        bootstrapEnrs: var seq[Record]) =
  if bootstrapFile.len == 0: return
  let ext = splitFile(bootstrapFile).ext
  if cmpIgnoreCase(ext, ".txt") == 0 or cmpIgnoreCase(ext, ".enr") == 0 :
    try:
      for ln in strippedLines(bootstrapFile):
        addBootstrapNode(ln, bootstrapEnrs)
    except IOError as e:
      fatal "Could not read bootstrap file", msg = e.msg
      quit 1
  else:
    fatal "Unknown bootstrap file format", ext
    quit 1
