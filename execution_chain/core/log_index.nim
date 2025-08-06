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
  nimcrypto/sha2,
  ssz_serialization,
  stew/bitops2

export hashes, receipts
# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  MAX_EPOCH_HISTORY* = 1
  MAP_WIDTH* = 16
  MAPS_PER_EPOCH* = 8
  MAX_BASE_ROW_LENGTH* = 4096



# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

when not declared(ExecutionAddress):
  type ExecutionAddress* = Address

type
  FilterRow* =
    ByteList[MAX_BASE_ROW_LENGTH * log2trunc(MAP_WIDTH) # 8 * MAPS_PER_EPOCH]

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
    lrkLog   

  LogRecord* = object
    case kind*: LogRecordKind
    of lrkDelimiter:
      block*: BlockDelimiterEntry
    of lrkLog:
      entry*: LogEntry

  LogIndexEpoch* = object
    ## Per-epoch log index data
    records*: Table[uint64, LogRecord]
    log_index_root*: Hash32

  LogIndex* = object
    ## Container holding log entries and index bookkeeping data
    epochs*: Vector[LogIndexEpoch, MAX_EPOCH_HISTORY]
    next_index*: uint64
    ## Debugging helpers tracking latest operations
    latest_block_delimiter_index*: uint64
    latest_block_delimiter_root*: Hash32
    latest_log_entry_index*: uint64
    latest_log_entry_root*: Hash32
    latest_value_index*: uint64
    latest_layer_index*: uint64
    latest_row_index*: uint64
    latest_column_index*: uint64
    latest_log_value*: Hash32
    latest_row_root*: Hash32

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc address_value*(address: ExecutionAddress): Hash32 =
  sha256.digest(address.data).to(Hash32)

proc topic_value*(topic: Hash32): Hash32 =
  sha256.digest(topic.data).to(Hash32)

proc add_log_value*(log_index: var LogIndex,
                    layer, row, column: uint64,
                    value_hash: Hash32) =
  ## Stub: assign index to hashed address/topic and increment counter
  log_index.latest_value_index = log_index.next_index
  log_index.latest_layer_index = layer
  log_index.latest_row_index = row
  log_index.latest_column_index = column
  log_index.latest_log_value = value_hash
  log_index.next_index.inc

proc hash_tree_root*(li: LogIndex): Hash32 =
  sha256.digest($li.next_index).to(Hash32)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc add_block_logs*(log_index: var LogIndex, block: Block) =
  log_index.latest_value_index = log_index.next_index
  log_index.latest_log_value = value_hash
  log_index.next_index.inc

proc hash_tree_root*(li: LogIndex): Hash32 =
  sha256.digest($li.next_index).to(Hash32)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc add_block_logs*(log_index: var LogIndex, block: Block) =
  if log_index.epochs[0].records.isNil:
    log_index.epochs[0].records = initTable[uint64, LogRecord]()

  if block.header.number > 0:
  if log_index.epochs[0].records.isNil:
    log_index.epochs[0].records = initTable[uint64, LogRecord]()

  if block.header.number > 0:
    let delimiter = BlockDelimiterEntry(blockNumber: block.header.number)
    log_index.epochs[0].records[log_index.next_index] =
      LogRecord(kind: lrkDelimiter, block: delimiter)
    log_index.latest_block_delimiter_index = log_index.next_index
    log_index.latest_block_delimiter_root = hash_tree_root(log_index)
    log_index.next_index.inc

  for txPos, receipt in block.receipts:
    for logPos, log in receipt.logs:
      let meta = LogMeta(
        blockNumber: block.header.number,
        txIndex: uint32(txPos),
        logIndex: uint32(logPos)
      )
      let entry = LogEntry(log: log, meta: meta)
      log_index.epochs[0].records[log_index.next_index] =
        LogRecord(kind: lrkLog, entry: entry)

      log_index.latest_log_entry_index = log_index.next_index
      log_index.latest_log_entry_root = hash_tree_root(log_index)
      log_index.next_index.inc

      add_log_value(log_index, 0, 0, 0, address_value(log.address))
      for topic in log.topics:
        add_log_value(log_index, 0, 0, 0, topic_value(topic.data.to(Hash32)))

  log_index.epochs[0].log_index_root = hash_tree_root(log_index)
  log_index.latest_row_root = log_index.epochs[0].log_index_root
  log_index.latest_layer_index = 0
  log_index.latest_row_index = 0
  log_index.latest_column_index = 0

{.pop.}