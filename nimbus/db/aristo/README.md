Aristo Trie -- a Patricia Trie with Merkle hash labeled edges
=============================================================
These data structures allows to overlay the *Patricia Trie* with *Merkel
Trie* hashes. With a particular layout, the structure is called
and *Aristo Trie* (Patricia = Roman Aristocrat, Patrician.)

This description does assume familiarity with the abstract notion of a hexary
*Merkle Patricia [Trie](https://en.wikipedia.org/wiki/Trie)*. Suffice it to
say the state of a valid *Merkle Patricia Tree* is uniquely verified by its
top level vertex.

Contents
--------
* [1. Deleting entries in a compact *Merkle Patricia Tree*](#ch1)

* [2. *Patricia Trie* example with *Merkle hash* labelled edges](#ch2)

* [3. Discussion of the examples *(1)* and *(3)*](#ch3)

* [4. *Patricia Trie* node serialisation with *Merkle hash* labelled edges](#ch4)
  + [4.1 Branch record serialisation](#ch4x1)
  + [4.2 Extension record serialisation](#ch4x2)
  + [4.3 Leaf record serialisation](#ch4x3)
  + [4.4 Leaf record payload serialisation for account data](#ch4x4)
  + [4.5 Leaf record payload serialisation for unstructured data](#ch4x5)
  + [4.6 Serialisation of the top used vertex ID](#ch4x6)
  + [4.7 Serialisation of a last saved state record](#ch4x7)
  + [4.8 Serialisation record identifier identification](#ch4x8)

* [5. *Patricia Trie* implementation notes](#ch5)
  + [5.1 Database decriptor representation](#ch5x1)
  + [5.2 Distributed access using the same backend](#ch5x2)

<a name="ch1"></a>
1. Deleting entries in a compact *Merkle Patricia Tree*
-------------------------------------------------------
The main feature of the *Aristo Trie* representation is that there are no
double used nodes any sub-trie as it happens with the representation as a
[compact Merkle Patricia Tree](http://archive.is/TinyK). For example,
consider the following state data for the latter.

      leaf = (0xf,0x12345678)                                            (1)
      branch = (a,a,a,,, ..) with a = hash(leaf)
      root = hash(branch)

These two nodes, called *leaf* and *branch*, and the *root* hash are a state
(aka key-value pairs) representation as a *compact Merkle Patricia Tree*. The
actual state is

      0x0f ==> 0x12345678
      0x1f ==> 0x12345678
      0x2f ==> 0x12345678

The elements from *(1)* can be organised in a key-value table with the *Merkle*
hashes as lookup keys

      a    -> leaf
      root -> branch

This is a space efficient way of keeping data as there is no duplication of
the sub-trees made up by the *Leaf* node with the same payload *0x12345678*
and path snippet *0xf*. One can imagine how this property applies to more
general sub-trees in a similar fashion.

Now delete some key-value pair of the state, e.g. for the key *0x0f*. This
amounts to removing the first of the three *a* hashes from the *branch*
record. The new state of the *Merkle Patricia Tree* will look like

      leaf = (0xf,0x12345678)                                            (2)
      branch1 = (,a,a,,, ..)
      root1 = hash(branch1)

      a     -> leaf
      root1 -> branch1

A problem arises when all keys are deleted and there is no reference to the
*leaf* data record, anymore. One should find out in general when it can be
deleted, too. It might be unknown whether the previous states leading to here
had only a single *Branch* record referencing to this *leaf* data record.

Finding a stale data record can be achieved by a *mark and sweep* algorithm,
but it becomes too clumsy to be useful on a large state (i.e. database).
Reference counts come to mind but maintaining these is generally error prone
when actors concurrently manipulate the state (i.e. database).

<a name="ch2"></a>
2. *Patricia Trie* example with *Merkle hash* labelled edges
------------------------------------------------------------
Continuing with the example from chapter 1, the *branch* node is extended by
an additional set of structural identifiers *x, w, z*. It allows to handle
the deletion of entries in a more benign way while keeping the *Merkle hashes*
for validating sub-trees.

A solution for the deletion problem is to represent the situation *(1)* as

      leaf-a = (0xf,0x12345678) copy of leaf from (1)                    (3)
      leaf-b = (0xf,0x12345678) copy of leaf from (1)
      leaf-c = (0xf,0x12345678) copy of leaf from (1)
      branch2 = ((x,y,z,,, ..)(a,b,c,,, ..))
      root2 = (w,root) with root from (1)

where

      a = hash(leaf-a) same as a from (1)
      b = hash(leaf-b) same as a from (1)
      c = hash(leaf-c) same as a from (1)

      w,x,y,z numbers, mutually different

The records above are stored in a key-value database as

      w -> branch2
      x -> leaf-a
      y -> leaf-b
      z -> leaf-c

Then this structure encodes the key-value pairs as before

      0x0f ==> 0x12345678
      0x1f ==> 0x12345678
      0x2f ==> 0x12345678

Deleting the data for key *0x0f* now results in the new state

      leaf-b = (0xf,0x12345678)                                          (4)
      leaf-c = (0xf,0x12345678)
      branch3 = ((,y,z,,, ..)(,b,c,,, ..))

      w -> branch3
      y -> leaf-b
      z -> leaf-c

Due to duplication of the *leaf* node in *(3)*, no reference count is needed
in order to detect stale records cleanly when deleting key *0x0f*. Removing
this key allows to remove hash *a* from *branch2* as well as also structural
key *x* which will consequently be deleted from the lookup table.

A minor observation is that manipulating a state entry, e.g. changing the
payload associated with key *0x0f* to

      0x0f ==> 0x987654321

the structural layout of the above trie will not change, that is the indexes
*w, x, y, z* of the table that holds the data records as values. All that
changes are values.

      leaf-d = (0xf,0x987654321)                                         (5)
      leaf-b = (0xf,0x12345678)
      leaf-c = (0xf,0x12345678)
      branch3 = ((x,y,z,,, ..)(d,b,c,,, ..))

      root3 = (w,hash(d,b,c,,, ..))

<a name="ch3"></a>
3. Discussion of the examples *(1)* and *(3)*
---------------------------------------------
Examples *(1)* and *(3)* differ in that the structural *Patricia Trie*
information from *(1)* has been removed from the *Merkle hash* instances and
implemented as separate table lookup IDs (called *vertexID*s later on.) The
values of these lookup IDs are arbitrary as long as they are all different.

In fact, the [Erigon](http://archive.is/6MJV7) project discusses a similar
situation in **Separation of keys and the structure**, albeit aiming for a
another scenario with the goal of using mostly flat data lookup structures.

A graph for the example *(1)* would look like

                |
               root
                |
         +-------------+
         |   branch    |
         +-------------+
              | | |
              a a a
              | | |
              leaf

while example *(2)* has

              (root)                                                     (6)
                |
                w
                |
         +-------------+
         |   branch2   |
         | (a) (b) (c) |
         +-------------+
            /   |   \
           x    y    z
          /     |     \
       leaf-a leaf-b leaf-c

The labels on the edges indicate the downward target of an edge while the
round brackets enclose separated *Merkle hash* information.

This last example (6) can be completely split into structural tree and Merkel
hash mapping.

         structural trie              hash map                           (7)
         ---------------              --------
                |                  (root) -> w
                w                     (a) -> x
                |                     (b) -> y
         +-------------+              (c) -> z
         |   branch2   |
         +-------------+
            /   |   \
           x    y    z
          /     |     \
       leaf-a leaf-b leaf-c


<a name="ch4"></a>
4. *Patricia Trie* node serialisation with *Merkle hash* labelled edges
-----------------------------------------------------------------------
The data structure for the *Aristo Trie* forllows example *(7)* by keeping
structural information separate from the Merkle hash labels. As for teminology,

* an *Aristo Trie* is a pair *(structural trie, hash map)* where
* the *structural trie* realises a haxary *Patricia Trie* containing the payload
  values in the leaf records
* the *hash map* contains the hash information so that this trie operates as a
  *Merkle Patricia Tree*.

In order to accommodate for the additional structural elements, a non RLP-based
data layout is used for the *Branch*, *Extension*, and *Leaf* containers used
in the key-value table that implements the *Patricia Trie*. It is now called
*Aristo Trie* for this particular data layout.

The structural keys *w, x, y, z* from the example *(3)* are called *vertexID*
and implemented as 64 bit values, stored *Big Endian* in the serialisation.

<a name="ch4x1"></a>
### 4.1 Branch record serialisation

        0 +--+--+--+--+--+--+--+--+--+
          |                          |       -- first vertexID
        8 +--+--+--+--+--+--+--+--+--+
          ...                                -- more vertexIDs
          +--+--+
          |     |                            -- access(16) bitmap
          +--+--+
          |  |                               -- marker(8), 0x08
          +--+

        where
          marker(8) is the eight bit array *0000-1000*

For a given index *n* between *0..15*, if the bit at position *n* of the bit
vector *access(16)* is reset to zero, then there is no *n*-th structural
*vertexID*. Otherwise one calculates

        the n-th vertexID is at position Vn * 8
        for Vn the number of non-zero bits in the range 0..(n-1) of access(16)

Note that data are stored *Big Endian*, so the bits *0..7* of *access* are
stored in the right byte of the serialised bitmap.

<a name="ch4x2"></a>
### 4.2 Extension record serialisation

        0 +--+--+--+--+--+--+--+--+--+
          |                          |       -- vertex ID
        8 +--+--+--+--+--+--+--+--+--+
          |  | ...                           -- path segment
          +--+
          || |                               -- marker(2) + pathSegmentLen(6)
          +--+

        where
          marker(2) is the double bit array 10

The path segment of the *Extension* record is compact encoded. So it has at
least one byte. The first byte *P0* has bit 5 reset, i.e. *P0 and 0x20* is
zero (bit 4 is set if the right nibble is the first part of the path.)

Note that the *pathSegmentLen(6)* is redunant as it is determined by the length
of the extension record (as *recordLen - 9*.)

<a name="ch4x3"></a>
### 4.3 Leaf record serialisation

        0 +-- ..
          ...                                -- payload (may be empty)
          +--+
          |  | ...                           -- path segment
          +--+
          || |                               -- marker(2) + pathSegmentLen(6)
          +--+

        where
          marker(2) is the double bit array 11

A *Leaf* record path segment is compact encoded. So it has at least one byte.
The first byte *P0* has bit 5 set, i.e. *P0 and 0x20* is non-zero (bit 4 is
also set if the right nibble is the first part of the path.)

If present, the serialisation of the payload field can be either for account
data, for RLP encoded or for unstructured data as defined below.

<a name="ch4x4"></a>
### 4.4 Leaf record payload serialisation for account data

        0 +-- ..  --+
          |         |                        -- nonce, 0 or 8 bytes
          +-- ..  --+--+
          |            |                     -- balance, 0, 8, or 32 bytes
          +-- ..  --+--+
          |         |                        -- storage ID, 0 or 8 bytes
          +-- ..  --+--+
          |            |                     -- code hash, 0, 8 or 32 bytes
          +--+ .. --+--+
          |  |                               -- 4 x bitmask(2), word array
          +--+

        where each bitmask(2)-word array entry defines the length of
        the preceeding data fields:
          00 -- field is missing
          01 -- field length is 8 bytes
          10 -- field length is 32 bytes

Apparently, entries 0 and and 2 of the *4 x bitmask(2)* word array cannot have
the two bit value *10* as they refer to the nonce and the storage ID data
fields. So, joining the *4 x bitmask(2)* word array to a single byte, the
maximum value of that byte is 0x99.

<a name="ch4x5"></a>
### 4.5 Leaf record payload serialisation for unstructured data

        0 +--+ .. --+
          |  |      |                        -- data, at least one byte
          +--+ .. --+
          |  |                               -- marker(8), 0x6b
          +--+

        where
          marker(8) is the eight bit array *0110-1011*

<a name="ch4x6"></a>
### 4.6 Serialisation of the top used vertex ID

        0 +--+--+--+--+--+--+--+--+
          |                       |          -- last used vertex IDs
        8 +--+--+--+--+--+--+--+--+
          |  |                               -- marker(8), 0x7c
          +--+

        where
          marker(8) is the eight bit array *0111-1100*

The vertex IDs in this record must all be non-zero. The last entry in the list
indicates that all ID values greater or equal than this value are free and can
be used as vertex IDs. If this record is missing, the value *(1u64,0x01)* is
assumed, i.e. the list with the single vertex ID *1*.

<a name="ch4x7"></a>
### 4.7 Serialisation of a last saved state record

         0 +--+--+--+--+--+ .. --+--+ .. --+
           |                               | -- 32 bytes state hash
        32 +--+--+--+--+--+ .. --+--+ .. --+
           |                       |         -- state number/block number
        40 +--+--+--+--+--+--+--+--+
           |  |                              -- marker(8), 0x7f
           +--+

        where
          marker(8) is the eight bit array *0111-111f*

<a name="ch4x8"></a>
### 4.8 Serialisation record identifier tags

Any of the above records can uniquely be identified by its trailing marker,
i.e. the last byte of a serialised record.

|** Bit mask**| **Hex value**    | **Record type**      |**Chapter reference**|
|:-----------:|:----------------:|:--------------------:|:-------------------:|
|   0000 1000 | 0x08             | Branch record        | [4.1](#ch4x1)       |
|   10xx xxxx | 0x80 + x(6)      | Extension record     | [4.2](#ch4x2)       |
|   11xx xxxx | 0xC0 + x(6)      | Leaf record          | [4.3](#ch4x3)       |
|   0xxx 0yyy | (x(3)<<4) + y(3) | Account payload      | [4.4](#ch4x4)       |
|   0110 1011 | 0x6b             | Unstructured payload | [4.5](#ch4x5)       |
|   0111 1100 | 0x7c             | Last used vertex ID  | [4.6](#ch4x6)       |
|   0111 1111 | 0x7f             | Last saved state     | [4.7](#ch4x7)       |

<a name="ch5"></a>
5. *Patricia Trie* implementation notes
---------------------------------------

<a name="ch5x1"></a>
### 5.1 Database decriptor representation

        ^      +----------+
        |      | top      |   active delta layer, application cache
        |      +----------+
        |      +----------+   ^
       db      | stack[n] |   |
       desc    |    :     |   |  optional passive delta layers, handled by
       obj     | stack[1] |   |  transaction management (can be used to
        |      | stack[0] |   |  successively recover the top layer)
        |      +----------+   v
        |      +----------+
        |      | balancer |   optional read-only backend filter
        |      +----------+
        |      +----------+
        |      | backend  |   optional physical key-value backend database
        v      +----------+

 There is a three tier access to a key-value database entry as in

        top -> balancer -> backend

where only the *top* layer is obligatory.

<a name="ch5x2"></a>
### 5.2 Distributed access using the same backend

There can be many descriptors for the same database. Due to delta layers and
filters, each descriptor instance can work with a different state of the
database.

Although there is only one of the instances that can write the current state
on the physical backend database, this priviledge can be shifted to any
instance for the price of updating the *roFiters* for all other instances.

#### Example:

        db1   db2   db3       -- db1, db2, .. database descriptors/handles
         |     |     |
        tx1   tx2   tx3       -- tx1, tx2, ..transaction/top layers
         |     |     |
         ø     ø     ø        -- no backend filters yet
          \    |    /
           \   |   /
              PBE             -- physical backend database

After collapse/committing *tx1* and saving it to the physical backend
database, the above architecture mutates to

        db1   db2   db3
         |     |     |
         ø    tx2   tx3
         |     |     |
         ø   ~tx1  ~tx1       -- filter reverting the effect of tx1 on PBE
          \    |    /
           \   |   /
            tx1+PBE           -- tx1 merged into physical backend database

When looked at descriptor API there are no changes when accessing data via
*db1*, *db2*, or *db3*. In a different, more algebraic notation, the above
tansformation is written as

        | tx1, ø |                                                   (8)
        | tx2, ø | PBE
        | tx3, ø |

            ||
            \/

        |  ø,    ø  |                                                (9)
        | tx2, ~tx1 | tx1+PBE
        | tx3, ~tx1 |

 The system can be further converted without changing the API by committing
 and saving *tx2* on the middle line of matrix (9)

        |  ø,       ø  |                                             (10)
        |  ø, tx2+~tx1 | tx1+PBE
        | tx3,    ~tx1 |

            ||
            \/

        |  ø,       ~(tx2+~tx1) |                                    (11)
        |  ø,               ø   | (tx2+~tx1)+tx1+PBE
        | tx3, ~tx1+~(tx2+~tx1) |

The *+* notation just means the repeated application of filters in
left-to-right order. The notation looks like algebraic group notation but this
will not be analysed further as there is no need for a general theory for the
current implementation.

Suffice to say that the inverse *~tx* of *tx* is calculated against the
current state of the physical backend database which makes it messy to
formulate boundary conditions.

Nevertheless, *(8)* can alse be transformed by committing and saving *tx2*
(rather than *tx1*.) This gives

        | tx1, ~tx2 |                                                (12)
        |  ø,    ø  | tx2+PBE
        | tx3, ~tx2 |

            ||
            \/

        |  ø, (tx1+~tx2) |                                           (13)
        |  ø,        ø   | tx2+PBE
        | tx3,     ~tx2  |

As *(11)* and *(13)* represent the same API, one has

        tx2+PBE =~ tx1+(tx2+~tx1)+PBE    because of the middle rows  (14)
        ~tx2    =~ ~tx1+~(tx2+~tx1)      because of (14)             (15)

which looks like some distributive property in *(14)* and commutative
property in *(15)* for this example (but it is not straight algebraically.)
The *=~* operator above indicates that the representations are equivalent in
the sense that they have the same effect on the backend database (looks a
bit like residue classes.)

It might be handy for testing/verifying an implementation using this example.
