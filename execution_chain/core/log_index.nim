# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE)) or
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[tables],
  eth/common/[blocks as ethblocks, receipts, hashes, addresses],
  nimcrypto/sha2

export hashes, receipts

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

when not declared(ExecutionAddress):
  type ExecutionAddress* = Address

type
  Block* = object
    ## Simplified block representation carrying header and receipts
    header*: ethblocks.Header
    receipts*: seq[Receipt]

# Metadata for a single log entry
# ---------------------------------------------------------------------------

type
  LogMeta* = object
    ## Metadata describing the location of a log
    blockNumber*: uint64
    txIndex*: uint32
    logIndex*: uint32

  LogEntry* = object
    ## Stored log together with metadata
    log*: Log
    meta*: LogMeta

  BlockDelimiterEntry* = object
    ## Special entry used to mark the boundary between blocks
    blockNumber*: uint64

  LogRecordKind* = enum
    lrkDelimiter,        ## Entry is a delimiter marking a new block
    lrkLog               ## Entry contains an actual log

  LogRecord* = object
    case kind*: LogRecordKind
    of lrkDelimiter:
      block*: BlockDelimiterEntry
    of lrkLog:
      entry*: LogEntry

  LogIndex* = object
    ## Container holding log entries and index bookkeeping data
    next_index*: uint64
    records*: Table[uint64, LogRecord]
    log_index_root*: Hash32

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc address_value*(address: ExecutionAddress): Hash32 =
  sha256.digest(address.data).to(Hash32)

proc topic_value*(topic: Hash32): Hash32 =
  sha256.digest(topic.data).to(Hash32)

# Stub implementation - later patches will expand this with proper mapping
proc add_log_value*(log_index: var LogIndex, value_hash: Hash32) =
  ## Stub: assign index to hashed address/topic and increment counter
  discard value_hash
  log_index.next_index.inc

proc hash_tree_root*(li: LogIndex): Hash32 =
  ## Minimal stand-in for SSZ hash tree root.
  ## Uses sha256 over the textual representation of the current index.
  sha256.digest($li.next_index).to(Hash32)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc add_block_logs*(log_index: var LogIndex, block: Block) =
  ## Add all logs from `block` to `log_index`.
  ##
  ## For blocks after genesis, a `BlockDelimiterEntry` is inserted prior to
  ## processing logs. Each receipt log is converted into a `LogEntry` with
  ## metadata describing its position. `add_log_value` is invoked for the log
  ## address and each topic which in this stub only advances the global index.
  ## Finally `log_index_root` is updated with a hash of the structure.
  if block.header.number > 0:
    let delimiter = BlockDelimiterEntry(blockNumber: block.header.number)
    log_index.records[log_index.next_index] =
      LogRecord(kind: lrkDelimiter, block: delimiter)
    log_index.next_index.inc

  for txPos, receipt in block.receipts:
    for logPos, log in receipt.logs:
      let meta = LogMeta(
        blockNumber: block.header.number,
        txIndex: uint32(txPos),
        logIndex: uint32(logPos)
      )
      let entry = LogEntry(log: log, meta: meta)
      log_index.records[log_index.next_index] =
        LogRecord(kind: lrkLog, entry: entry)

      add_log_value(log_index, address_value(log.address))
      for topic in log.topics:
        add_log_value(log_index, topic_value(topic.data.to(Hash32)))

  log_index.log_index_root = hash_tree_root(log_index)

{.pop.}