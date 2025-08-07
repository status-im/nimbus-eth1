# Create: tests/test_log_index.nim
import
  unittest2,
  ../execution_chain/core/log_index,

suite "EIP-7745 Log Index Tests":
  test "LogIndex basic initialization":
    var logIndex = LogIndex()
    check logIndex.next_index ==
     0
    echo "LogIndex test passed!"