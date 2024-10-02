Syncing
=======

Syncing blocks is performed in two partially overlapping phases

* loading the header chains into separate database tables
* removing headers from the headers chain, fetching the rest of the
  block the header belongs to and executing it

Header chains
-------------

The header chains are the triple of

* a consecutively linked chain of headers starting starting at Genesis
* followed by a sequence of missing headers
* followed by a consecutively linked chain of headers ending up at a
  finalised block header received from the consensus layer

A sequence *@[h(1),h(2),..]* of block headers is called a consecutively
linked chain if

* block numbers join without gaps, i.e. *h(n).number+1 == h(n+1).number*
* parent hashes match, i.e. *h(n).hash == h(n+1).parentHash*

General header chains layout diagram

      G                C                     L                F              (1)
      o----------------o---------------------o----------------o--->
      | <-- linked --> | <-- unprocessed --> | <-- linked --> |

Here, the single upper letter symbols *G*, *H*, *L*, *F* denote block numbers.
For convenience, these letters are also identified with its associated block
header or the full block. Saying *"the header G"* is short for *"the header
with block number G"*.

Meaning of *G*, *C*, *L*, *F*:

* *G* -- Genesis block number *#0*
* *C* -- coupler, maximal block number of linked chain starting at *G*
* *L* -- least, minimal block number of linked chain ending at *F* with *C <= L*
* *F* -- final, some finalised block

This definition implies *G <= C <= L <= F* and the header chains can uniquely
be described by the triple of block numbers *(C,L,F)*.

### Storage of header chains:

Some block numbers from the closed interval (including end points) *[G,C]* may
correspond to finalised blocks, e.g. the sub-interval *[G,**base**]* where
**base** is the block number of the ledger state. The headers for
*[G,**base**]* are stored in the persistent state database. The headers for the
half open interval *(**base**,C]* are always stored on the *beaconHeader*
column of the *KVT* database.

The block numbers from the interval *[L,F]* also reside on the *beaconHeader*
column of the *KVT* database table.

### Header chains initialisation:

Minimal layout on a pristine system

      G                                                                      (2)
      C
      L
      F
      o--->

When first initialised, the header chains are set to *(G,G,G)*.

### Updating header chains:

A header chain with an non empty open interval *(C,L)* can be updated only by
increasing *C* or decreasing *L* by adding headers so that the linked chain
condition is not violated.

Only when the open interval *(C,L)* vanishes the right end *F* can be increased
by *Z* say. Then

* *C==L* beacuse interval *(C,L)* is empty
* *C==F* because *C* is maximal

and the header chains *(F,F,F)* (depicted in *(3)*) can be set to *(C,Z,Z)*
(as depicted in *(4)*.)

Layout before updating of *F*

                       C                                                     (3)
                       L
      G                F                     Z
      o----------------o---------------------o---->
      | <-- linked --> |

New layout with *Z*

                                             L'                              (4)
      G                C                     F'
      o----------------o---------------------o---->
      | <-- linked --> | <-- unprocessed --> |

with *L'=Z* and *F'=Z*.

Note that diagram *(3)* is a generalisation of *(2)*.


### Complete header chain:

The header chain is *relatively complete* if it satisfies clause *(3)* above
for *G < C*. It is *fully complete* if *F==Z*. It should be obvious that the
latter condition is temporary only on a live system (as *Z* is permanently
updated.)

If a *relatively complete* header chain is reached for the first time, the
execution layer can start running an importer in the background compiling
or executing blocks (starting from block number *#1*.) So the ledger database
state will be updated incrementally.

Imported block chain
--------------------

The following imported block chain diagram amends the layout *(1)*:

      G                  B       C                     L                F    (5)
      o------------------o-------o---------------------o----------------o-->
      | <-- imported --> |       |                     |                |
      | <-------  linked ------> | <-- unprocessed --> | <-- linked --> |


where *B* is the **base**, i.e. the **base state** block number of the last
imported and executed block. It also refers to the global state block number of
the ledger database.

The headers corresponding to the half open interval `(B,C]` can be completed by
fetching block bodies and then imported/executed.

Running the sync process for *MainNet*
--------------------------------------

For syncing, a beacon node is needed that regularly informs via *RPC* of a
recently finalised block header.

The beacon node program used here is the *nimbus_beacon_node* binary from the
*nimbus-eth2* project (any other will do.) *Nimbus_beacon_node* is started as

      ./run-mainnet-beacon-node.sh \
         --web3-url=http://127.0.0.1:8551 \
         --jwt-secret=/tmp/jwtsecret

where *http://127.0.0.1:8551* is the URL of the sync process that receives the
finalised block header (here on the same physical machine) and `/tmp/jwtsecret`
is the shared secret file needed for mutual communication authentication.

It will take a while for *nimbus_beacon_node* to catch up (see the
[Nimbus Guide](https://nimbus.guide/quick-start.html) for details.)

### Starting `nimbus` for syncing

As the sync process is quite slow, it makes sense to pre-load the database
with data from an `Era1` archive (if available) before starting the real
sync process. The command would be something like

       ./build/nimbus import \
          --era1-dir:/path/to/main-era1/repo \
          ...

which will take a while for the full *MainNet* era1 repository (but way faster
than the sync.)

On a system with memory considerably larger than *8GiB* the *nimbus*
binary is started on the same machine where the beacon node runs as

       ./build/nimbus \
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
changes might be considered. For file
*nimbus-eth2/vendor/mainnet/metadata/config.yaml* change setting constants:

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

| *Variable*                     | *Logic type* | *Short description* |
|:-------------------------------|:------------:|:--------------------|
|                                |              |                     |
| beacon_base                    | block height | **B**, *increasing* |
| beacon_coupler                 | block height | **C**, *increasing* |
| beacon_least_block_number      | block height | **L**               |
| beacon_final_block_number      | block height | **F**, *increasing* |
| beacon_beacon_block_number     | block height | **Z**, *increasing* |
|                                |              |                     |
| beacon_headers_staged_queue_len| size | # of staged header list records      |
| beacon_headers_unprocessed     | size | # of accumulated header block numbers|
| beacon_blocks_staged_queue_len | size | # of staged block list records       |
| beacon_blocks_unprocessed      | size | # of accumulated body block numbers  |
|                                |              |                     |
| beacon_number_of_buddies       | size         | # of working peers  |
