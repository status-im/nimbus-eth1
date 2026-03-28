# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import unittest2, ../../execution_chain/concurrency/readwritelock


suite "ReadWriteLock Tests":

  test "init, dispose":
    block:
      var rwLock = ReadWriteLock.init()
      rwLock.dispose()

    block:
      var rwLock: ReadWriteLock
      rwLock.init()
      rwLock.dispose()

  test "lock/unlock write":
    var rwLock = ReadWriteLock.init()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

    rwLock.lockWrite()
    check:
      rwLock.hasWriter == true
      rwLock.readerCount == 0

    #rwLock.lockWrite() # is blocked

    rwLock.unlockWrite()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

  test "lock/unlock read":
    var rwLock = ReadWriteLock.init()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

    rwLock.lockRead()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 1

    rwLock.lockRead()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 2

    rwLock.lockRead()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 3
    
    #rwLock.lockWrite() # is blocked

    rwLock.unlockRead()
    rwLock.unlockRead()
    rwLock.unlockRead()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

  test "lock/unlock read then write":
    var rwLock = ReadWriteLock.init()

    rwLock.lockRead()
    rwLock.unlockRead()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

    rwLock.lockWrite()
    check:
      rwLock.hasWriter == true
      rwLock.readerCount == 0

    rwLock.unlockWrite()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

  test "lock/unlock write then read":
    var rwLock = ReadWriteLock.init()

    rwLock.lockWrite()
    rwLock.unlockWrite()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

    rwLock.lockRead()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 1

    rwLock.unlockRead()
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

  test "withReadLock":
    var rwLock = ReadWriteLock.init()

    var x: int
    withReadLock(rwLock):
      inc x
      check:
        rwLock.hasWriter == false
        rwLock.readerCount == 1
      
      rwLock.lockRead()
      check:
        rwLock.hasWriter == false
        rwLock.readerCount == 2
      rwLock.unlockRead()
  
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

  test "withWriteLock":
    var rwLock = ReadWriteLock.init()

    var x: int
    withWriteLock(rwLock):
      inc x
      check:
        rwLock.hasWriter == true
        rwLock.readerCount == 0
  
    check:
      rwLock.hasWriter == false
      rwLock.readerCount == 0

  test "Misc operations":
    var rwLock = ReadWriteLock.init()

    rwLock.lockRead()
    rwLock.unlockRead()
    rwLock.lockWrite()
    rwLock.unlockWrite()

    rwLock.lockRead()
    rwLock.lockRead()
    rwLock.lockRead()
    rwLock.unlockRead()
    rwLock.unlockRead()
    rwLock.unlockRead()
    rwLock.lockWrite()
    rwLock.unlockWrite()