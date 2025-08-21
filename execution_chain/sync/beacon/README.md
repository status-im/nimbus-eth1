Beacon Sync
===========

For handling block chain imports and related actions, abstraction methods
from the `forked_chain` module will be used (abbreviated **FC**.) The **FC**
entities **base** and **latest** from this module are always printed **bold**.

The *Consensus Layer* is abbreviated **CL**.

Sync Logic Outline
------------------

Here is a simplification of the sync process intended to provide a mental
outline of how it works.

In the following block chain layouts, a left position always stands for an
ancestor of a right one.

        0------C1                                                            (1)

        0--------L1                                                          (2)
                \_______H1

        0------------------C2                                                (3)

        0--------------------L2                                              (4)
                            \________H2

where

* *0* is genesis
* *C1*, *C2* are the *latest* (aka cursor) entities from the **FC** module
* *L1*, *L2*, are updated *latest* entities from the **FC** module
* *H1*, *H2* are block headers (or blocks) that are used as sync targets

At stage *(1)*, there is a chain of imported blocks *0..C1* (written as
compact interval of block numbers.)

At stage *(2)*, there is a sync request to advance up until block *H1* which
is then fetched from the network along with its ancestors way back until there
is an ancestor within the chain of imported blocks *0..L1*. The chain *0..L1*
is what the *0..C1* has morphed into when the chain of blocks ending at *H1*
finds its ancestor.

At stage *(3)* all blocks recently fetched have now been imported via **FC**.
In addition to that, there might have been additional imports from other
entities (e.g. `newPayload`) which has advanced *H1* further to *C2*.

Stage *(3)* has become similar to stage *(1)* with *C1* renamed as *C2*, ditto
for the symbols *L2* and *H2* for stage *(4)*.


Implementation, The Gory Details
--------------------------------

The following diagram depicts a most general state view of the sync and the
*FC* modules and at a given point of time

        0                    L                                               (5)
        o--------------------o
        | <--- imported ---> |
                     C                     D                            H
                     o---------------------o----------------------------o
                     | <-- unprocessed --> | <-- fetched and linked --> |

where a single letter symbol on the right has a higher block number than the
symbol on the left. Single letter symbol have the following meaning:

* *B* -- **base**, current value of this entity (with the same name) of the
         **FC** module (i.e. the current value when looked up.) *B* is an
		 ancestor or equal of *L* and would be somewhere between *0* and *L*
		 on the diagram *(5)*.

* *C* -- coupler, least possible endpoint *D* of the chain of headers to be
         fetched and and linked.

* *I* -- imported, last block that was sucsessfully imported into the **FC**
         module (this symbol is potentally used in code comments of the
		 implementation, only.)

* *L* -- **latest**, current value of this entity (with the same name) of the
         **FC** module (i.e. the current value when looked up.) *L* need not
         be a parent of any header of the linked chain `D..H` as both, *L* and
		 *H* might be heads of different chains.

* *D* -- dangling, header with the least block number of the linked chain in
         progress ending at *H*. This variable is used to record the download
         state. When successful, downloading ends when header *D* has a parent
		 on the **FC** database.

* *H* -- head, sync target header which locks the value of *T* (see below)
         while processing.

* *T* -- cached value of the last *consensus head* request (interpreted as
         *sync to new head* instruction) sent from the **CL** via RPC (this
         symbol is potentally used in code comments of the implementation,
		 only.)

### Sync Processing

The syncer starts at an idle state

        0            B       L                                               (6)
        o------------o-------o
        | <--- imported ---> |

Following, there will be a request from the **CL** to advance to a new
position *H* as indicated in *(7)* below

        0            B       L                                               (7)
        o------------o-------o
        | <--- imported ---> |
                     C                                                D H
                     o------------------------------------------------o-o
                     | <----------------- unprocessed --------------> |

where *blockNumber(D)+1 == blockNumber(H)*. For the *unprocessed* headers
of *C..D*, all that is known are the block number and the hash
of *D* (via *H* parent hash.)

The syncer fetches the unprocessed header chain *C..D* from the network top
down starting at *D*. The fetched headers are stored temporarily on the
*header chain cache* which is an **FC** sub-module. This process stops when
the *header chain cache* signals that the current header *D* has a parent on
the **FC** database. The syncer it will continue with the next task importing
blocks.

It might also be signalled that there cannot be such a parent on the **FC**
database in which case sync processing restarts at clause *(6)*.

        0              B     L                                               (8)
        o--------------o-----o
        | <--- imported ---> |
                     C    D                                             H
                     o----o---------------------------------------------o
                          | <----------- fetched and inked -----------> |

Then block bodies are fetched for headers *D..H* and imported/executed
starting at header *D*.

While processing, due to interference by *RPC* actions, the internal state
of the **FC** might change/reset so that further import becomes infeasible.
Even when starting, the block *D* might not have a parent on **FC** anymore.
In any of those cases, sync processing restarts immediately at clause *(6)*.

Otherwise sync processing restarts when after the last block for *H* was
fetched and imported.


Running the sync process for *MainNet*
--------------------------------------

In order to run productively, a layer 1/consensus layer application needs to
drive the layer 2/execution later application. Here the *nimbus_beacon_node*
binary is used as a consensus layer application. It is from the *nimbus-eth2*
project (any other, e.g.the *light client*  will do.)

*Nimbus_beacon_node* is started as

      ./run-mainnet-beacon-node.sh \
         --web3-url=http://127.0.0.1:8551 \
         --jwt-secret=/tmp/jwtsecret

where *http://127.0.0.1:8551* is the URL of the sync process that receives the
finalised block header (here on the same physical machine) and `/tmp/jwtsecret`
is the shared secret file needed for mutual communication authentication.

It will take a while for *nimbus_beacon_node* to catch up (see the
[Nimbus Guide](https://nimbus.guide/quick-start.html) for details.)

### Starting `nimbus` for syncing

As the syncing process is quite slow, it makes sense to pre-load the database
from an *Era1* and *Era* archives (if available) before starting the real sync
process. The command for importing an *Era1* and *Era* reprositories would be
something like

       ./build/nimbus_execution_client import \
          --era1-dir:/path/to/main-era1/repo \
          --era-dir:/path/to/main-era/repo \
          ...

which will take its time for the full *MainNet* Era1 repository (but way faster
than the beacon sync.)

On a system with memory considerably larger than *8GiB* the *nimbus* binary is
started on the same machine where the beacon node runs with the command


       ./build/nimbus_execution_client \
          --engine-api=true \
          --engine-api-port=8551 \
          --engine-api-ws=true \
          --jwt-secret=/tmp/jwtsecret \
          ...

Note that *--engine-api-port=8551* and *--jwt-secret=/tmp/jwtsecret* match
the corresponding options from the *nimbus-eth2* beacon source example.

### Pre-initialising the syncer for debugging

For testing/debugging purposes, the initial sync target can be set on the
command line without need to be requested by the consensus layer. In fact,
this allows for single run synchronisation tests without the need of a
consensus layer. The command line option needed here is

       --beacon-sync-target=<hash32>

where *&lt;hash32&gt;* is a hexadecimal ASCII representation of a block
header. The hashes for particular blocks can be looked up at *etherscan.io*.
For testing, only finalised hblock headers should be referred to in which
case the option

       --beacon-sync-target-is-final

should be set. This reduces the potential memory footprint when running
without a CL.

### Syncing on a low memory machine

On a system with memory around *8GiB* the following additional options proved
useful for *nimbus* to reduce the memory footprint.

For the *Era1*/*Era* pre-load (if any) the following extra options apply to
"*nimbus import*":

       --chunk-size=1024
       --debug-rocksdb-row-cache-size=512000
       --debug-rocksdb-block-cache-size=1500000

To start syncing, the following additional options apply to *nimbus*:

       --debug-beacon-blocks-queue-hwm=1500
       --debug-rocksdb-max-open-files=384
       --debug-rocksdb-write-buffer-size=50331648
       --debug-rocksdb-block-cache-size=1073741824
       --debug-rdb-key-cache-size=67108864
       --debug-rdb-vtx-cache-size=268435456

Also, to reduce the backlog for *nimbus-eth2* stored on disk, the following
changes might be considered. In the file
*nimbus-eth2/vendor/mainnet/metadata/config.yaml* change the folloing
settings

       MIN_EPOCHS_FOR_BLOCK_REQUESTS: 33024
       MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS: 4096
to

       MIN_EPOCHS_FOR_BLOCK_REQUESTS: 8
       MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS: 8

Caveat: These changes are not useful when running *nimbus_beacon_node* as a
production system.

Metrics
-------

The following metrics are defined in *worker/update/metrics.nim* which will
be available if *nimbus* is compiled with the additional make flags
*NIMFLAGS="-d:metrics \-\-threads:on"*:

| *Variable*                   | *Logic type* | *Short description*  |
|:-----------------------------|:------------:|:---------------------|
|                              |              |                      |
| nec_base                     | block height | **B**, *increasing*  |
| nec_execution_head           | block height | **L**, *increasing*  |
| nec_sync_coupler             | block height | **C**, *0 when idle* |
| nec_sync_dangling            | block height | **D**, *0 when idle* |
| nec_sync_last_block_imported | block height | **I**, *0 when idle* |
| nec_sync_head                | block height | **H**, *0 when idle* |
| nec_sync_consensus_head      | block height | **T**, *increasing*  |
|                              |              |                      |
| nec_sync_header_lists_staged | size | # of staged header list records      |
| nec_sync_headers_unprocessed | size | # of accumulated header block numbers|
| nec_sync_block_lists_staged  | size | # of staged block list records       |
| nec_sync_blocks_unprocessed  | size | # of accumulated body block numbers  |
|                              |      |                                      |
| nec_sync_peers               | size | # of peers working concurrently      |
| nec_sync_non_peers_connected | size | # of other connected peers           |

### Graphana example

There is an [example configuration](#Grafana-example.json) for the syncer on
**mainnet** for the Grafana metrics display server. For this example, Grafana
is configured on top of prometheus which in turn is configured roughly as

      /etc/prometheus/prometheus.yml:
        [..]
        scrape_configs:
          [..]
          # Use "ip addr add 172.16.210.1/24 dev lo" if there is no
          # such interface address "172.16.210.1" on the local network
          - job_name: mainnet
            static_configs:
            - targets: ['172.16.210.1:9099']

The nimbus_ececution client is supposed to run with the additional
command line arguments (note that port *9099* is default)

      --metrics-address=172.16.210.1 --metrics-port=9099

A general [Metric visualisation](https://github.com/status-im/nimbus-eth1?tab=readme-ov-file#metric-visualisation) setup is described as part of the
introductory [README.md](../../../README.md) of the *nimbus-eth1* package.
