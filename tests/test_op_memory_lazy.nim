import macro_assembler, unittest2, macros, strutils

proc opMemoryLazyMain*() =
  suite "Lazy Loading With Memory Opcodes":
    let (vmState, chainDB) = initDatabase()

    assembler: # SLOAD OP with (fake) lazy data fetching
      title: "LAZY_SLOAD_1"
      initialStorage:
        "0xAA": "0x42"
      code:
        PUSH1 "0xAA"
        SLOAD
        PUSH1 "0x01"
        ADD
        PUSH1 "0xAA"
        SSTORE
        PUSH1 "0xAA"
        SLOAD
      storage:
        "0xAA": "0x43"
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000043"

    let (vmState1, chainDB1) = initDatabase()
    let (vmState2, chainDB2) = initDatabase()
    concurrentAssemblers:
      title: "Concurrent Assemblers"
      assemblers:
        asm1:
          title: "asm1"
          vmState: vmState1
          chainDB: chainDB1
          initialStorage:
            "0xBB": "0x42"
            "0xCC": "0x20"
          code:
            PUSH1 "0xBB"
            SLOAD
            PUSH1 "0xCC"
            SLOAD
            ADD
            PUSH1 "0xBB"
            SSTORE
            PUSH1 "0xBB"
            SLOAD
          storage:
            "0xBB": "0x62"
            "0xCC": "0x20"
          stack: "0x0000000000000000000000000000000000000000000000000000000000000062"
        asm2:
          title: "asm2"
          vmState: vmState2
          chainDB: chainDB2
          initialStorage:
            "0xDD": "0x30"
            "0xEE": "0x20"
          code:
            PUSH1 "0xDD"
            SLOAD
            PUSH1 "0xEE"
            SLOAD
            ADD
            PUSH1 "0xEE"
            SSTORE
            PUSH1 "0xEE"
            SLOAD
          storage:
            "0xDD": "0x30"
            "0xEE": "0x50"
          stack: "0x0000000000000000000000000000000000000000000000000000000000000050"

when isMainModule:
  opMemoryLazyMain()
