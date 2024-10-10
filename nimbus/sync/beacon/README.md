Beacon Sync
===========

According to the merge-first
[glossary](https://notes.status.im/nimbus-merge-first-el?both=#Glossary),
a beacon sync is a "*Sync method that relies on devp2p and eth/6x to fetch
headers and bodies backwards then apply these in the forward direction to the
head state*".

This [glossary](https://notes.status.im/nimbus-merge-first-el?both=#Glossary)
is used as a naming template for relevant entities described here. When
referred to, names from the glossary are printed **bold**.

Syncing blocks is performed in two overlapping phases

* loading header chains and stashing them into a separate database table,
* removing headers from the stashed headers chain, fetching the block bodies
  the headers refer to and importing/executing them via `persistentBlocks()`.

So this beacon syncer slightly differs from the definition in the
[glossary](https://notes.status.im/nimbus-merge-first-el?both=#Glossary) in
that only headers are stashed on the database table and the block bodies are
fetched in the *forward* direction.

The reason for that behavioural change is that the block bodies are addressed
by the hash of the block headers for fetching. They cannot be fully verified
upon arrival on the cheap (e.g. by a payload hash.) They will be validated not
before imported/executed. So potentially corrupt blocks will be discarded.
They will automatically be re-fetched with other missing blocks in the
*forward* direction.


Header chains
-------------

The header chains are the triple of

* a consecutively linked chain of headers starting starting at Genesis
* followed by a sequence of missing headers
* followed by a consecutively linked chain of headers ending up at a
  finalised block header (earlier received from the consensus layer)

A sequence *@[h(1),h(2),..]* of block headers is called a *linked chain* if

* block numbers join without gaps, i.e. *h(n).number+1 == h(n+1).number*
* parent hashes match, i.e. *h(n).hash == h(n+1).parentHash*

General header linked chains layout diagram

      0                C                     D                E              (1)
      o----------------o---------------------o----------------o--->
      | <-- linked --> | <-- unprocessed --> | <-- linked --> |

Here, the single upper letter symbols *0*, *C*, *D*, *E* denote block numbers.
For convenience, these letters are also identified with its associated block
header or the full blocks. Saying *"the header 0"* is short for *"the header
with block number 0"*.

Meaning of *0*, *C*, *D*, *E*:

* *0* -- Genesis, block number number *0*
* *C* -- coupler, maximal block number of linked chain starting at *0*
* *D* -- dangling, minimal block number of linked chain ending at *E*
         with *C <= D*
* *E* -- end, block number of some finalised block (not necessarily the latest
         one)

This definition implies *0 <= C <= D <= E* and the state of the header linked
chains can uniquely be described by the triple of block numbers *(C,D,E)*.


### Storage of header chains:

Some block numbers from the closed interval (including end points) *[0,C]* may
correspond to finalised blocks, e.g. the sub-interval *[0,**base**]* where
**base** is the block number of the ledger state. The headers for
*[0,**base**]* are stored in the persistent state database. The headers for the
half open interval *(**base**,C]* are always stored on the *beaconHeader*
column of the *KVT* database.

The block numbers from the interval *[D,E]* also reside on the *beaconHeader*
column of the *KVT* database table.


### Header linked chains initialisation:

Minimal layout on a pristine system

      0                                                                      (2)
      C
      D
      E
      o--->

When first initialised, the header linked chains are set to *(0,0,0)*.


### Updating a header linked chains:

A header chain with an non empty open interval *(C,D)* can be updated only by
increasing *C* or decreasing *D* by adding/prepending headers so that the
linked chain condition is not violated.

Only when the gap open interval *(C,D)* vanishes, the right end *E* can be
increased to a larger target block number *T*, say. This block number will
typically be the **consensus head**. Then

* *C==D* beacuse the open interval *(C,D)* is empty
* *C==E* because *C* is maximal (see definition of `C` above)

and the header chains *(E,E,E)* (depicted in *(3)* below) can be set to
*(C,T,T)* as depicted in *(4)* below.

Layout before updating of *E*

                       C                                                     (3)
                       D
      0                E                     T
      o----------------o---------------------o---->
      | <-- linked --> |

New layout with moving *D* and *E* to *T*

                                             D'                              (4)
      0                C                     E'
      o----------------o---------------------o---->
      | <-- linked --> | <-- unprocessed --> |

with *D'=T* and *E'=T*.

Note that diagram *(3)* is a generalisation of *(2)*.


### Complete a header linked chain:

The header chain is *relatively complete* if it satisfies clause *(3)* above
for *0 < C*. It is *fully complete* if *E==T*. It should be obvious that the
latter condition is temporary only on a live system (as *T* is contiuously
updated.)

If a *relatively complete* header chain is reached for the first time, the
execution layer can start running an importer in the background
compiling/executing blocks (starting from block number *#1*.) So the ledger
database state will be updated incrementally.

Block chain import/execution
-----------------------------

The following diagram with a parially imported/executed block chain amends the
layout *(1)*:

      0                  B       C                     D                E    (5)
      o------------------o-------o---------------------o----------------o-->
      | <-- imported --> |       |                     |                |
      | <-------  linked ------> | <-- unprocessed --> | <-- linked --> |


where *B* is the **base**, i.e. the **base state** block number of the last
imported/executed block. It also refers to the global state block number of
the ledger database.

The headers corresponding to the half open interval `(B,C]` will be completed
by fetching block bodies and then import/execute them together with the already
cached headers.


Running the sync process for *MainNet*
--------------------------------------

For syncing, a beacon node is needed that regularly informs via *RPC* of a
recently finalised block header.

The beacon node program used here is the *nimbus_beacon_node* binary from the
*nimbus-eth2* project (any other, e.g.the *light client*  will do.)
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
from an *Era1* archive (if available) before starting the real sync process.
The command for importing an *Era1* reproitory would be something like

       ./build/nimbus_execution_client import \
          --era1-dir:/path/to/main-era1/repo \
          ...

which will take its time for the full *MainNet* Era1 repository (but way faster
than the beacon sync.)

On a system with memory considerably larger than *8GiB* the *nimbus* binary is
started on the same machine where the beacon node runs with the command


       ./build/nimbus_execution_client \
          --network=mainnet \
          --engine-api=true \
          --engine-api-port=8551 \
          --engine-api-ws=true \
          --jwt-secret=/tmp/jwtsecret \
          ...

Note that *--engine-api-port=8551* and *--jwt-secret=/tmp/jwtsecret* match
the corresponding options from the *nimbus-eth2* beacon source example.

### Syncing on a low memory machine

On a system with memory with *8GiB* the following additional options proved
useful for *nimbus* to reduce the memory footprint.

For the *Era1* pre-load (if any) the following extra options apply to
"*nimbus import*":

       --chunk-size=1024
       --debug-rocksdb-row-cache-size=512000
       --debug-rocksdb-block-cache-size=1500000

To start syncing, the following additional options apply to *nimbus*:

       --debug-beacon-chunk-size=384
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

| *Variable*         | *Logic type* | *Short description* |
|:-------------------|:------------:|:--------------------|
|                    |              |                     |
| beacon_base        | block height | **B**, *increasing* |
| beacon_coupler     | block height | **C**, *increasing* |
| beacon_dangling    | block height | **D**               |
| beacon_end         | block height | **E**, *increasing* |
| beacon_target      | block height | **T**, *increasing* |
|                            |      |                     |
| beacon_header_lists_staged | size | # of staged header list records      |
| beacon_headers_unprocessed | size | # of accumulated header block numbers|
| beacon_block_lists_staged  | size | # of staged block list records       |
| beacon_blocks_unprocessed  | size | # of accumulated body block numbers  |
|                            |      |                                      |
| beacon_buddies             | size | # of peers working concurrently      |
