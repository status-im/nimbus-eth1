import
  ../execution_chain/core/log_index,
  eth/common/[receipts, blocks],
  unittest2

suite "Basic LogIndex Test":
  test "LogIndex initializes correctly":
    let logIndex = initLogIndex()
    check:
      logIndex.next_index == 0
      logIndex.epochs.len == 0

  test "LogIndex processes empty block":
    var logIndex = initLogIndex()
    let header = Header(number: 1)
    let receipts: seq[Receipt] = @[]
    
    let beforeIndex = logIndex.next_index
    logIndex.add_block_logs(header, receipts)
    
    echo "Before: ", beforeIndex, ", After: ", logIndex.next_index
    check logIndex.next_index > beforeIndex