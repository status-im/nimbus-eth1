# Fluffy
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles,
  confutils,
  stint,
  eth/keys,
  ../database/content_db,
  ./benchmark

when defined(posix):
  import system/ansi_c

type Timers = enum
  tDbPut = "DB put for content"
  tDbGet = "DB get for content"
  tDbContains = "DB contains for content"
  tDbDel = "DB delete for content"
  tDbSize = "Get DB size"
  tDbUsedSize = "Get DB used size"
  tDbContentSize = "Get DB content size"
  tDbContentCount = "Get DB content count"
  tDbLargestDistance = "Get DB largest distance"

type
  DbCmd* {.pure.} = enum
    benchmark = "Run a benchmark on different ContentDb calls. This is invasive to the database as it will add but then also remove new random content"
    generate = "Generate random content into the database, for testing purposes."
    prune = "Prune the ContentDb in case of resizing or selecting a different local id"
    validate = "Validate all the content in the ContentDb"

  DbConf = object
    databaseDir* {.
      desc: "Directory where `contentdb_xxx.sqlite` is stored"
      name: "db-dir".}: InputDir

    contentSize* {.
      desc: "Amount of bytes in generated content value"
      defaultValue: 25_000 # 25kb
      name: "content-size".}: uint64

    case cmd* {.
      command
      desc: ""
      .}: DbCmd

    of DbCmd.benchmark:
      samples* {.
        desc: "Amount of benchmark samples"
        defaultValue: 100
        name: "samples".}: uint64

    of DbCmd.generate:
      contentAmount* {.
        desc: "Amount of content key-value pairs to generate in db"
        defaultValue: 1000
        name: "content-amount".}: uint64

    of DbCmd.prune:
      discard

    of DbCmd.validate:
      discard

const maxDbSize = 4_000_000_000'u64

func generateRandomU256(rng: var HmacDrbgContext): UInt256 =
  let bytes = rng.generateBytes(32)
  UInt256.fromBytesBE(bytes)

proc cmdGenerate(conf: DbConf) =
  let
    rng = newRng()
    db = ContentDB.new(
      conf.databaseDir.string,
      maxDbSize,
      inMemory = false)
    bytes = newSeq[byte](conf.contentSize)

  for i in 0..<conf.contentAmount:
    let key = rng[].generateRandomU256()
    db.put(key, bytes)

proc cmdBench(conf: DbConf) =
  let
    rng = newRng()
    db = ContentDB.new(
      conf.databaseDir.string,
      4_000_000_000'u64,
      inMemory = false)
    bytes = newSeq[byte](conf.contentSize)

  var timers: array[Timers, RunningStat]
  var keys: seq[UInt256]

  # TODO: We could/should avoid putting and deleting content by iterating over
  # some content and selecting random content keys for which to get the content.
  for i in 0..<conf.samples:
    let key = rng[].generateRandomU256()
    keys.add(key)
    withTimer(timers[tDbPut]):
      db.put(key, bytes)

  for key in keys:
    withTimer(timers[tDbGet]):
      let val = db.get(key)

  for key in keys:
    withTimer(timers[tDbContains]):
      discard db.contains(key)

  for key in keys:
    withTimer(timers[tDbDel]):
      db.del(key)

  for i in 0..<conf.samples:
    withTimer(timers[tDbSize]):
      let size = db.size()
    withTimer(timers[tDbUsedSize]):
      let size = db.usedSize()
    withTimer(timers[tDbContentSize]):
      let size = db.contentSize()
    withTimer(timers[tDbContentCount]):
      let count = db.contentCount()
    withTimer(timers[tDbLargestDistance]):
      # The selected local ID doesn't matter here as it currently needs to
      # iterate over all content for this call.
      let distance = db.getLargestDistance(u256(0))

  printTimers(timers)

proc controlCHook {.noconv.} =
  notice "Shutting down after having received SIGINT."
  quit QuitSuccess

proc exitOnSigterm(signal: cint) {.noconv.} =
  notice "Shutting down after having received SIGTERM."
  quit QuitSuccess

when isMainModule:
  setControlCHook(controlCHook)
  when defined(posix):
    c_signal(ansi_c.SIGTERM, exitOnSigterm)

  var conf = DbConf.load()

  case conf.cmd
  of DbCmd.benchmark:
    cmdBench(conf)
  of DbCmd.generate:
    cmdGenerate(conf)
  of DbCmd.prune:
    notice "Functionality not yet implemented"
  of DbCmd.validate:
    notice "Functionality not yet implemented"
