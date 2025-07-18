Beacon sync tracer
==================

With the command line option *\-\-debug-beacon-sync-trace-file=<dump-file>*
for the *nimbus_execution_client* binary, data from the syncer sessions will
be dumped into the argument file *<dump-file>* along with system state
information.

The data captured is enough to replay the *nimbus_execution_client* sessions.

By default, the captured syncer session starts with the first syncer activation
(when *Activating syncer* is logged) and ends when the syncer is suspended
(when *Suspending syncer* is logged.)

The trace file *<dump-file>* is organised as an ASCII text file, each line
consists of a data capture record. The line format is

    <format> <capture-data>

where the *<format>* is a single alphanumeric letter, and *<capture-data>* is
a base64 representation of an rlp-encoded data capture structure.

By nature of the base64 representation, the size of the trace data is about
four times the data capture which leads to huge files, e.g. some 30GiB for the
last 120k blocks synchronised on *mainnet*.

The file with the captured data may be gzipped after the dump finished which
reduces ths size roughly to 1/3. So altogether in its gzipped form, the size
of the gzipped trace file is about 4/3 of the capured data (mainly downloaded
block headers and bodies.)

The captured data might be further processed (e.g. inspection or replay) in
its gzipped form.
