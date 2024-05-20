Test & debugging scenario with nimbus-eth1 client/server
========================================================


Start snap/1 server
-------------------

  # Enter nimbus directory for snap/1 protocol server.
  cd server

  # Tell nimbus to stop full sync after 2 mio blocks.
  echo 2000000 > full-limit.txt

  # Tell nimbus to use this predefined key ID
  echo 123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0 > full-id.key

  ./build/nimbus \
    --tcp-port:30319 --nat=None --sync-mode=full \
	--protocols=snap --discovery=none \
	--net-key=./full-id.key \
	--sync-ctrl-file=./full-limit.txt \
	--log-level:TRACE

  # Wait for several hours until enough blocks have been downloaded so that
  # snap sync data are available. The full 2 mio blocks are available if the
  # log ticker shows something like
  #
  # INF 2023-03-17 [..] Sync statistics (suspended) topics="full-tick" [..] persistent=#2000080 [..]
  #
  # where the persistent=#2000080 field might vary


Start snap/1 client
-------------------

  # Note: When the snap/1 server has enough blocks, the client can be started.

  # Enter nimbus directory for snap/1 protocol server
  cd client

  # Tell nimbus to use this pivot block number. This number must be smaller
  # than the 2000000 written into the file full-limit.txt above.
  echo 600000 > snap/snap-update.txt

  # Tell nimbus to stop somewhere after 1000000 blocks have been downloaded
  # with full sync follow up after snap sync has completed (2nd line of
  # external setuip file.)
  echo 1000000 >> snap/snap-update.txt

  # Tell nimbus to use this hard coded peer enode.
  echo enode://192d7e7a302bd4ff27f48d7852621e0d3cb863a6dd67dd44e0314a25a3aa866837f0d2460b4444dc66e7b7a2cd56a2de1c31b2a2ba4e23549bf3ba3b0c4f2eb5@127.0.0.1:30319 > snap/full-servers.txt

  ./build/nimbus \
    --tcp-port:30102 --nat=None --sync-mode=snap \
	--protocols=none --discovery=none \
	--static-peers-file=./full-servers.txt \
	--sync-ctrl-file=./snap-update.txt \
	--log-level:TRACE


Modifications while the programs are syncing
--------------------------------------------

  # Increasing the number in the files full/full-limit.txt or
  # snap/snap-update.txt will be recognised while running. Decreasing
  # or removing will be ignored.

