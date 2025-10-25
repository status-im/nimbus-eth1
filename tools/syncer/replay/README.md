Inspection of Capture Data And Replay
=====================================

Inspection
----------

Given a (probably *gzipped*) capture file **(capture)** as a result of
tracing, its content can be visualised as a space separated list of
selected text fields via

       ./build/syncer_test_client_inspect --capture-file=(capture)

As the **(capture)** is a list of *JSON* text lines, the *gunzipped* version
can also can be inspected with a text editor (or perusal pager *more* or
*less*.).

Replay
------

Copy the current database directory **(database)** and its recursive content
as **(dbcopy)**, say. Then start a capture session on the original data base
via

       ./build/syncer_test_client_trace \
          --datadir=(database) ... -- --capture-file=(capture)

where **...** stands for all other options that might be useful for running
an execution layer session and **(capture)** will collect all the data needed
for replay. This file can become quite huge. It should be *gzipped* after the
capture run has finished and the *gzipped* version used, instead.

Monitor the capture run so it can be stopped at an appropriate state using
metrics or logs. With the above command line arguments, only a single sync
session is logged ranging from the first activation message (when *"Activating
syncer"* is logged) up until the suspend message (when *"Suspending syncer"*
is logged.)

Now, the captured session can be replayed on the secured database copy
**(dbcopy)** with the (probably *gzipped*) **(capture)** file via

       ./build/syncer_test_client_replay \
          --datadir=(dbcopy) ... -- --capture-file=(capture)

where ihe additional arguments **...** of either command above need not be
the same.

Note that you need another copy of the original **(database)** if you need to
re-exec the latter command line statement for another replay.
