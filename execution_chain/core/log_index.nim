# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE)) or
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[tables, sequtils],
  eth/common/[blocks as ethblocks, receipts, hashes, addresses],
  nimcrypto/[hash, sha2],
  ssz_serialization,
  stew/bitops2

export hashes, receipts

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  MAX_EPOCH_HISTORY* = 1
  MAP_WIDTH* = 16
  MAP_WIDTH_LOG2* = 4  # log2(16) = 4
  MAP_HEIGHT* = 256          
  MAPS_PER_EPOCH* = 8
  VALUES_PER_MAP* = 1024     
  MAX_BASE_ROW_LENGTH* = 4096
  LAYER_COMMON_RATIO* = 2
  EIP7745_ACTIVATION_BLOCK* = 999999999  # Very high block number for testing

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

when not declared(ExecutionAddress):
  type ExecutionAddress* = Address

type
  FilterRow* =
    ByteList[MAX_BASE_ROW_LENGTH * MAP_WIDTH_LOG2 * MAPS_PER_EPOCH]

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
      delimiter*: BlockDelimiterEntry
    of lrkLog:
      entry*: LogEntry

  LogIndexEpoch* = object
    ## Per-epoch log index data
    records*: Table[uint64, LogRecord]
    log_index_root*: Hash32

type
  LogIndexSummary* = object
    ## Summary structure that goes into block header (256 bytes total)
    root*: Hash32                      # 0x00 - log_index.hash_tree_root()
    epochs_root*: Hash32                # 0x20 - log_index.epochs.hash_tree_root()
    epoch_0_filter_maps_root*: Hash32  # 0x40 - log_index.epochs[0].filter_maps.hash_tree_root()
    latest_block_delimiter_index*: uint64  # 0x60
    latest_block_delimiter_root*: Hash32   # 0x68
    latest_log_entry_index*: uint64        # 0x88
    latest_log_entry_root*: Hash32         # 0x90
    latest_value_index*: uint32            # 0xb0
    latest_layer_index*: uint32            # 0xb4
    latest_row_index*: uint32              # 0xb8
    latest_column_index*: uint32           # 0xbc
    latest_log_value*: Hash32              # 0xc0
    latest_row_root*: Hash32               # 0xe0

  LogIndex* = object
    ## Container holding log entries and index bookkeeping data
    epochs*: seq[LogIndexEpoch]
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

  LogIndexDigest* = object
    root*: Hash32
    epochs_root*: Hash32
    epoch_0_filter_maps_root*: Hash32

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------
proc shouldUseLogIndex*(blockNumber: uint64): bool =
  result = blockNumber >= EIP7745_ACTIVATION_BLOCK

proc zeroHash32(): Hash32 =
  ## Create a zero-filled Hash32
  var zero_array: array[32, byte]
  result = Hash32(zero_array)

# ---------------------------------------------------------------------------
# Constructor Functions
# ---------------------------------------------------------------------------

proc initLogIndexEpoch*(): LogIndexEpoch =
  ## Initialize a new LogIndexEpoch with empty table
  result.records = initTable[uint64, LogRecord]()
  result.log_index_root = zeroHash32()

proc initLogIndex*(): LogIndex =
  ## Initialize a new LogIndex with default values
  result.epochs = @[]
  result.next_index = 0
  result.latest_block_delimiter_index = 0
  result.latest_block_delimiter_root = zeroHash32()
  result.latest_log_entry_index = 0
  result.latest_log_entry_root = zeroHash32()
  result.latest_value_index = 0
  result.latest_layer_index = 0
  result.latest_row_index = 0
  result.latest_column_index = 0
  result.latest_log_value = zeroHash32()
  result.latest_row_root = zeroHash32()

# ---------------------------------------------------------------------------
# Binary Conversion Helpers
# ---------------------------------------------------------------------------

proc toBinary64*(value: uint64): array[8, byte] =
  ## Convert uint64 to little-endian byte array
  for i in 0..7:
    result[i] = byte((value shr (i * 8)) and 0xFF)

proc toBinary32*(value: uint32): array[4, byte] =
  ## Convert uint32 to little-endian byte array
  for i in 0..3:
    result[i] = byte((value shr (i * 8)) and 0xFF)

proc fromBinary32*(data: array[4, byte]): uint32 =
  ## Convert little-endian byte array to uint32
  for i in 0..3:
    result = result or (uint32(data[i]) shl (i * 8))

# ---------------------------------------------------------------------------
# Hash Functions
# ---------------------------------------------------------------------------

proc fnv1a_hash*(data: openArray[byte]): uint64 =
  ## FNV-1a hash function as required by EIP-7745
  const FNV_OFFSET_BASIS = 14695981039346656037'u64
  const FNV_PRIME = 1099511628211'u64
  
  var hash = FNV_OFFSET_BASIS
  for b in data:
    hash = hash xor uint64(b)
    hash = hash * FNV_PRIME
  result = hash

# Replace your current hash functions with:
proc log_value_hash*(data: openArray[byte]): Hash32 =
  ## Generic hash function for log values as per EIP-7745
  var ctx: sha256
  ctx.init()
  ctx.update(data)
  let digest = ctx.finish()
  result = Hash32(digest.data)

proc address_value*(address: ExecutionAddress): Hash32 =
  ## Hash address for log value indexing
  log_value_hash(cast[array[20, byte]](address))

proc topic_value*(topic: Hash32): Hash32 =
  ## Hash topic for log value indexing  
  log_value_hash(cast[array[32, byte]](topic))

proc hash_tree_root*(li: LogIndex): Hash32 =
  ## Compute SSZ hash tree root of LogIndex (simplified for M0)
  var ctx: sha256
  ctx.init()
  ctx.update(toBinary64(li.next_index))
  let digest = ctx.finish()
  result = Hash32(digest.data)

# ---------------------------------------------------------------------------
# Filter Map Functions (Simplified for M0)
# ---------------------------------------------------------------------------

proc get_column_index*(log_value_index: uint64, log_value: Hash32): uint64 =
  ## Simplified column index calculation for M0
  var hash_input: seq[byte]
  hash_input.add(toBinary64(log_value_index))
  hash_input.add(cast[array[32, byte]](log_value))
  
  let column_hash = fnv1a_hash(hash_input)
  result = column_hash mod uint64(MAP_WIDTH)

proc get_row_index*(map_index: uint64, log_value: Hash32, layer_index: uint64): uint64 =
  ## Simplified row index calculation for M0
  var hash_input: seq[byte]
  hash_input.add(cast[array[32, byte]](log_value))
  hash_input.add(toBinary64(map_index))
  hash_input.add(toBinary64(layer_index))
  
  let column_hash = fnv1a_hash(hash_input)
  result = column_hash mod uint64(MAP_HEIGHT)

proc add_log_value*(log_index: var LogIndex,
                    layer, row, column: uint64,
                    value_hash: Hash32) =
  ## Add a log value to the index with filter map coordinates
  # Update tracking fields
  log_index.latest_value_index = log_index.next_index
  log_index.latest_layer_index = layer
  log_index.latest_row_index = row
  log_index.latest_column_index = column
  log_index.latest_log_value = value_hash
  
  # TODO: Implement actual filter map insertion logic for full EIP-7745
  # For M0, we just track the coordinates
  
  log_index.next_index.inc

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
proc encodeLogIndexSummary*(summary: LogIndexSummary): seq[byte] =
  ## Manually encode LogIndexSummary to ensure exactly 256 bytes
  result = newSeq[byte](256)
  
  # Helper to copy bytes
  template copyBytes(dest: var seq[byte], offset: int, src: pointer, size: int) =
    if size > 0:
      copyMem(addr dest[offset], src, size)
  
  # Encode each field at the correct offset
  copyBytes(result, 0x00, unsafeAddr summary.root, 32)
  copyBytes(result, 0x20, unsafeAddr summary.epochs_root, 32)
  copyBytes(result, 0x40, unsafeAddr summary.epoch_0_filter_maps_root, 32)
  copyBytes(result, 0x60, unsafeAddr summary.latest_block_delimiter_index, 8)
  copyBytes(result, 0x68, unsafeAddr summary.latest_block_delimiter_root, 32)
  copyBytes(result, 0x88, unsafeAddr summary.latest_log_entry_index, 8)
  copyBytes(result, 0x90, unsafeAddr summary.latest_log_entry_root, 32)
  copyBytes(result, 0xb0, unsafeAddr summary.latest_value_index, 4)
  copyBytes(result, 0xb4, unsafeAddr summary.latest_layer_index, 4)
  copyBytes(result, 0xb8, unsafeAddr summary.latest_row_index, 4)
  copyBytes(result, 0xbc, unsafeAddr summary.latest_column_index, 4)
  copyBytes(result, 0xc0, unsafeAddr summary.latest_log_value, 32)
  copyBytes(result, 0xe0, unsafeAddr summary.latest_row_root, 32)

proc add_block_logs*(log_index: var LogIndex, 
                     header: ethblocks.Header, 
                     receipts: seq[StoredReceipt]) =
  
  # echo "=== add_block_logs called ==="
  # echo "  Block number: ", header.number
  # echo "  Receipts count: ", receipts.len
  # echo "  Starting next_index: ", log_index.next_index
  
  # Initialize epochs if needed
  if log_index.epochs.len == 0:
    log_index.epochs.add(initLogIndexEpoch())
    # echo "  Initialized epochs"

  # Count total logs first
  var totalLogs = 0
  for receipt in receipts:
    when compiles(receipt.logs):
      totalLogs += receipt.logs.len
  # echo "  Total logs to process: ", totalLogs

  # Add block delimiter for non-genesis blocks
  if header.number > 0:
    # echo "  Adding block delimiter at index ", log_index.next_index
    let delimiter = BlockDelimiterEntry(blockNumber: header.number)
    log_index.epochs[0].records[log_index.next_index] =
      LogRecord(kind: lrkDelimiter, delimiter: delimiter)
    log_index.latest_block_delimiter_index = log_index.next_index
    log_index.latest_block_delimiter_root = hash_tree_root(log_index)
    log_index.next_index.inc
    # echo "  Block delimiter added, next_index now: ", log_index.next_index

  # Process all logs in all receipts
  for txPos, receipt in receipts:
    when compiles(receipt.logs):  # Check if receipt has logs field
      # echo "  Processing receipt ", txPos, " with ", receipt.logs.len, " logs"
      for logPos, log in receipt.logs:
        # echo "    Adding log ", logPos, " at index ", log_index.next_index
        
        # Create log entry with metadata
        let meta = LogMeta(
          blockNumber: header.number,
          txIndex: uint32(txPos),
          logIndex: uint32(logPos)
        )
        let entry = LogEntry(log: log, meta: meta)
        
        # Store log entry
        log_index.epochs[0].records[log_index.next_index] =
          LogRecord(kind: lrkLog, entry: entry)

        log_index.latest_log_entry_index = log_index.next_index
        log_index.latest_log_entry_root = hash_tree_root(log_index)
        log_index.next_index.inc
        # echo "    Log stored, next_index incremented to: ", log_index.next_index

        # Process log values (address + topics)
        let addr_hash = address_value(log.address)
        let column = get_column_index(log_index.next_index - 1, addr_hash)
        let row = get_row_index(0, addr_hash, 0)
        # echo "    Calling add_log_value for address at row=", row, ", column=", column
       # add_log_value(log_index, 0, row, column, addr_hash)
        # echo "    After add_log_value, next_index is: ", log_index.next_index
        
        # Process each topic
        # echo "    Processing ", log.topics.len, " topics"
        for i in 0..<log.topics.len:
          let topic = log.topics[i]
          let topic_hash = topic_value(Hash32(topic))
          let topic_column = get_column_index(log_index.next_index - 1, topic_hash)
          let topic_row = get_row_index(0, topic_hash, 0)
          # echo "      Topic ", i, ": calling add_log_value at row=", topic_row, ", column=", topic_column
          add_log_value(log_index, 0, topic_row, topic_column, topic_hash)
          # echo "      After topic add_log_value, next_index is: ", log_index.next_index

  # Update epoch root
  log_index.epochs[0].log_index_root = hash_tree_root(log_index)
  log_index.latest_row_root = log_index.epochs[0].log_index_root
  
  # echo "  Final next_index: ", log_index.next_index
  # echo "=== add_block_logs done ===\n"

proc getLogIndexDigest*(li: LogIndex): LogIndexDigest =
  ## Produce digest for LogIndexSummary generation
  result.root = hash_tree_root(li)
  
  # Generate epochs root (simplified for M0)
  if li.epochs.len > 0:
    result.epochs_root = li.epochs[0].log_index_root
  else:
    result.epochs_root = zeroHash32()
  
  # For M0, we use a simplified filter maps root
  result.epoch_0_filter_maps_root = result.epochs_root  # Simplified for M0

proc createLogIndexSummary*(li: LogIndex): LogIndexSummary =
  ## Create LogIndexSummary for block header
  let digest = li.getLogIndexDigest()
  
  result.root = digest.root
  result.epochs_root = digest.epochs_root
  result.epoch_0_filter_maps_root = digest.epoch_0_filter_maps_root
  result.latest_block_delimiter_index = li.latest_block_delimiter_index
  result.latest_block_delimiter_root = li.latest_block_delimiter_root
  result.latest_log_entry_index = li.latest_log_entry_index
  result.latest_log_entry_root = li.latest_log_entry_root
  result.latest_value_index = uint32(li.latest_value_index)
  result.latest_layer_index = uint32(li.latest_layer_index)
  result.latest_row_index = uint32(li.latest_row_index)
  result.latest_column_index = uint32(li.latest_column_index)
  result.latest_log_value = li.latest_log_value
  result.latest_row_root = li.latest_row_root


# ---------------------------------------------------------------------------
# Reorg Handling (Basic Implementation)
# ---------------------------------------------------------------------------

proc rewind_to_block*(log_index: var LogIndex, target_block_number: uint64) =
  ## Basic reorg handling - remove entries after target block
  if log_index.epochs.len == 0:
    return
    
  var indices_to_remove: seq[uint64]
  
  for index, record in log_index.epochs[0].records.pairs:
    let should_remove = case record.kind:
      of lrkDelimiter: record.delimiter.blockNumber > target_block_number
      of lrkLog: record.entry.meta.blockNumber > target_block_number
    
    if should_remove:
      indices_to_remove.add(index)
  
  # Remove invalid entries
  for index in indices_to_remove:
    log_index.epochs[0].records.del(index)
  
  # Reset next_index
  if log_index.epochs[0].records.len > 0:
    let keys = toSeq(log_index.epochs[0].records.keys)
    log_index.next_index = max(keys) + 1
  else:
    log_index.next_index = 0

{.pop.}