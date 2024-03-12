Nimbus-eth1 -- Ethereum execution layer database architecture
=============================================================
Last update: 2024-03-08

The following diagram gives a simplified view how components relate with
regards to the data storage management.

An arrow between components **a** and **b** (as in *a->b*) is meant to be read
as **a** relies directly on **b**, or **a** is served by **b**. For classifying
the functional type of a component in the below diagram, the abstraction type
is enclosed in brackets after the name of a component.

* *(application)*<br>
  This is a group of software modules at the top level of the hierarchy. In the
  diagram below, the **EVM** is used as an example. Another application might
  be the **RPC** service.

* *(API)*<br>
  The *API* classification is used for a thin software layer hiding a set of
  different drivers where only one driver is active for the same *API*
  instance. It servers as sort of a logical switch.

* *(concentrator)*<br>
  The *concentrator* merges several sub-module instances and provides their
  collected services as a single unified instance. There is not much additional
  logic implemented besides what the sub-modules provide.

* *(driver)*<br>
  The *driver* instances are sort of the lower layer workhorses. The implement
  logic for solving a particular problem, providing a typically well defined
  service, etc.

* *(engine)*<br>
  This is a bottom level *driver* in the below diagram.

                                            +-------------------+
                                            | EVM (application) |
                                            +-------------------+
                                                 |          |
                                                 v          |
                              +-------------------------+   |
                              | State DB (concentrator) |   |
                              +-------------------------+   |
                                  |           |       |     |
                                  v           |       |     |
         +----------------------------+       |       |     |
         |       Ledger (API)         |       |       |     |
         +----------------------------+       |       |     |
                      |      |                |       |     |
                      v      v                |       |     |
         +--------------+  +--------------+   |       |     |
         | legacy cache |  | ledger cache |   |       |     |
         |   (driver)   |  |   (driver)   |   |       |     |
         +--------------+  +--------------+   |       |     |
                      |      |                v       |     |
                      |      |   +----------------+   |     |
                      |      |   |   Common       |   |     |
                      |      |   | (concentrator) |   |     |
                      |      |   +----------------+   |     |
                      |      |         |              |     |
                      v      v         v              v     v
         +---------------------------------------------------------------------+
         |               Core DB (API)                                         |
         +---------------------------------------------------------------------+
                         |                  |
                         v                  v
         +--------------------------+   +--------------------------------------+
         | legacy DB (concentrator) |   |   Aristo DB (driver,concentrator)    |
         +--------------------------+   +--------------------------------------+
               |                 |                |          |
               v                 |                v          v
         +--------------------+  |     +--------------+  +---------------------+
         | Hexary DB (driver) |  |     | Kvt (driver) |  | Aristo MPT (driver) |
         +--------------------+  |     +--------------+  +---------------------+
               |                 |                |          |
               v                 v                |          |
         +--------------------------+             |          |
         | Key-value table (driver) |             |          |
         +--------------------------+             |          |
                      |                           |          |
                      v                           v          v
         +---------------------------------------------------------------------+
         |                Rocks DB (engine)                                    |
         +---------------------------------------------------------------------+

Here is a list of path references for the components with some explanation.
The sources for the components are not always complete but indicate the main
locations where to start looking at.

* *Aristo DB (driver)*<a name="add"></a>
  + Sources:<br>
    ./nimbus/db/core_db/backend/aristo_*<br>

  + Synopsis:<br>
    Combines both, the *Kvt* and the *Aristo* driver sub-modules providing an
    interface similar to the [legacy DB (concentrator)](#ldc) module.

* *Aristo MPT (driver)*<a name="amd"></a>
  + Sources:<br>
    ./nimbus/db/aristo*

  + Synopsis:<br>
    Revamped implementation of a hexary *Merkle Patricia Tree*.

* *Common (concentrator)*<a name="cc"></a>
    * Sources:<br>
      ./nimbus/common*<br>

    * Synopsis:<br>
      Collected information for running block chain execution layer
      applications.

* *Core DB (API)*<a name="cda"></a>
  * Sources:<br>
    ./nimbus/db/core_db*

  * Synopsis:<br>
    Database abstraction layer. Unless for legacy applications, there should
    be no need to reach out to the layers below.

* *EVM (application)*<a name="ea"></a>
  + Sources:<br>
    ./nimbus/core/executor/*
    ./nimbus/evm/*

  + Synopsis:<br>
    An implementation of the *Ethereum Virtual Machine*.

* *Hexary DB (driver)*<a name="hdd"></a>
  + Sources:<br>
    ./vendor/nim-eth/eth/trie/hexary.nim<br>

  + Synopsis:<br>
    Implementation of an MPT, see
    [compact Merkle Patricia Tree](http://archive.is/TinyK).

* *Key-value table (driver)*<a name="kvtd"></a>
  + Sources:<br>
    ./vendor/nim-eth/eth/trie/db.nim<br>

  + Synopsis:<br>
    Key value table interface to be used directly for key-value storage or
    by the [Hexary DB (driver)](#hdd) module for storage. Some magic is applied
    in order to treat hexary data accordingly (based on key length.)

* *Kvt (driver)*<a name="kd"></a>
  + Sources:<br>
    ./nimbus/db/kvt*

  + Synopsis:<br>
    Key value table interface for the [Aristo DB (driver)](#add) module.
    Contrary to the [Key-value table (driver)](#kvtd), it is not used for
    MPT data.

* *Ledger (API)*<a name="la"></a>
  + Sources:<br>
    ./nimbus/db/ledger*

  + Synopsis:<br>
    Abstraction layer for either the [legacy cache (driver)](#lgcd) accounts
    cache (which works with the [legacy DB (driver)](#ldd) backend only) or
    the [ledger cache (driver)](#ldcd) re-write which is supposed to work
    with all [Core DB (API)](#cda) backends.

* *ledger cache (driver)*<a name="ldcd"></a>
  + Sources:<br>
    ./nimbus/db/ledger/accounts_ledger.nim<br>
    ./nimbus/db/ledger/backend/accounts_ledger*<br>
    ./nimbus/db/ledger/distinct_ledgers.nim

  + Synopsis:<br>
    Management of accounts and storage data. This is a re-write of the
    [legacy DB (driver)](#lgdd)  which is supposed to work with all
    [Core DB (API)](#cda) backends.

* *legacy cache (driver)*<a name="lgcd"></a>
  + Sources:<br>
    ./nimbus/db/distinct_tries.nim<br>
    ./nimbus/db/ledger/accounts_cache.nim<br>
    ./nimbus/db/ledger/backend/accounts_cache*

  + Synopsis:<br>
    Management of accounts and storage data. It works only for the legacy
    driver of the [Core DB (API)](#cda) backend.

* *legacy DB (concentrator)*<a name="ldc"></a>
  + Sources:<br>
    ./nimbus/db/core_db/backend/legacy_*

  + Synopsis:<br>
    Legacy database abstraction. It mostly forwards requests directly to the
    to the [Key-value table (driver)](#kvtd) and/or the
    [hexary DB (driver)](#hdd).

* *Rocks DB (engine)*<a name="rde"></a>
  + Sources:<br>
    ./vendor/nim-rocksdb/*

  + Synopsis:<br>
    Persistent storage engine.

* *State DB (concentrator)*<a name="sdc"></a>
  + Sources:<br>
    ./nimbus/evm/state.nim<br>
    ./nimbus/evm/types.nim

  + Synopsis:<br>
    Integrated collection of modules and methods relevant for the EVM.

