#! /bin/sh

self=${NIMBUS_SESSION_SELF:-`basename "$0"`}

# Network name (used below for easy setup)
name=${NIMBUS_SESSION_NAME:-devnet4}

# Unique Nimbus TCP/UDP communication port
port=${NIMBUS_SESSION_PORT:-30309}

# Unique log data and database folder (relative to current directory)
datadir=./datadir-${name}

# Name of custom genesis and bootstrap files
genesis_json=${name}.json
bootstrap_txt=${name}-enode.txt

# -------- no need to change, below -------------

# More Nimbus option arguments
min_peers=2
ttd=5000000000

# Log spooler capacity settings
logfile_max=80000000
num_backlogs=40

# Base directory for finding objects in the Nimbus file system
find_prefix="`dirname $0` . .. ../.. nimbus-eth1"

# Sub-find directory for various items
find_nimbus=". build"
find_genesis=". tests/customgenesis"
find_bootstrap=". tests/customgenesis"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Find executable file
find_exe() { # Syntax: <exe-name> <subdir> ...
    exe="$1"
    shift
    for pfx in $find_prefix; do
	for sub; do
	    find -L \
		"$pfx/$sub" \
		-maxdepth 2 -type f -name "$exe" -perm /111 -print \
		2>/dev/null
	done
    done |
	# Beware, this is slow. On the other hand, uncommenting the next line
	# dumps all possible matches to the console.
	#tee /dev/tty |
	sed \
	    -e 's|^|'"$PWD/"'|' \
	    -e 's|/\./|/|g' \
	    -e 's|/\./|/|g' \
	    -eq
}

# Find non-executable file
find_file() { # Syntax: <file-name> <subdir> ...
    file="$1"
    shift
    for pfx in $find_prefix; do
	for sub; do
	    find -L \
		"$pfx/$sub" \
		-maxdepth 2 -type f -name "$file" -print \
		2>/dev/null
	done
    done |
	# Beware, this is slow. On the other hand, uncommenting the next line
	# dumps all possible matches to the console.
	#tee /dev/tty |
	sed \
	    -e 's|^|'"$PWD/"'|' \
	    -e 's|/\./|/|g' \
	    -e 's|/\./|/|g' \
	    -eq
}

stripColors() {
  if ansi2txt </dev/null 2>/dev/null
  then
      ansi2txt
  else
      cat
  fi
}

# Find pid of running svlogd command
get_pid_svlogd() {
    ps x|
	grep \
	    -e "svlogd $datadir/log" \
        |
	grep -v \
	     -e vim \
	     -e grep \
        |
	awk '$1 != '"$$"'{print $1}'
}

# Find pid of running svlogd and nimbus command
get_pids() {
    ps x|
	grep \
	    -e "nimbus .* --tcp-port:$port" \
	    -e "svlogd $datadir/log" \
        |
	grep -v \
	     -e vim \
	     -e grep \
        |
	awk '$1 != '"$$"'{print $1}'
}

# ------------------------------------------------------------------------------
# Command line parsing and man page
# ------------------------------------------------------------------------------

nohup=no
start=no
stop=no
flush=no
logs=no
help=no

test $# -ne 0 ||
    help=yes

for arg
do
    case "$arg" in
    stop)
	stop=yes
	;;
    flush)
	flush=yes
	;;
    start)
	start=yes
	;;
    daemon)
	nohup=yes
	start=yes
	;;
    logs)
	logs=yes
	;;
    help|'')
	help=yes
	;;
  *)
      exec >&2
      echo "Usage: $self [help] [stop] [flush] [daemon|start] [logs]"
      exit 2
  esac
done


test yes != "$help" || {
    cat <<EOF
$self:
   The script manages a Nimbus session for Devnet4. It was inspired by running
   a test node remotely on a cloud exposed server for syncing. The script will
   start the "nimbus" program and maintain database and log files in the folder
   $datadir.

   The script must be run from the "nimbus-eth1" base directory or from one of
   its sub-directories. In the simple case, the script is run as

     sh $self start

   which will run Nimbus in the background and print the logs on the console.
   With ctrl-C, the program is stopped. In order to run in the background, the
   the "nimbus" program is started with

     sh $self daemon

   Continuous logging can then be displayed on the console (hit ctrl-C to stop)
   with

      sh $self logs

   A running background session is stopped with

      sh $self stop

   Log data are held in sort of a fifo and can be inspected with

      cat $datadir/log/* | less

   Available commands (can be combined irrespective of order):

      start   start the Nimbus session in the foreground
      daemon  background session (without termninating on logout, e.g. from ssh)
      stop    stop the Nimbus session (as descibed above)
      logs    resume console logging (as descibed above)
      flush   delete all log and blockchain data

   Hint: If the program "ansi2txt" is not available (part of package
         "colorized-logs" on Debian), Nimbus should be compiled as

      make nimbus NOCOLOR=1

   so that logfiles become decolorised and better readable and parseable.
EOF
    exit
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

# Check for logger program availability
(svlogd 2>&1|grep -i 'usage: svlogd' >/dev/null) || {
  exec >&2
  echo "*** $self: This script needs a working \"svlogd\" program. On Debian,"
  echo "                    this is provided by the \"runit\" package."
  exit 2
}

# Stop running sessions by sending termination signal
test yes != "$stop" || {
  # set -x
  pids=`get_pids`
  test -z "$pids" || {
      (set -x; kill -TERM $pids)
      sleep 1
      pids=`get_pids`
      test -z "$pids" || {
	  (set -x; kill -KILL $pids)
	  sleep 1
      }
      echo
  }
}

# Clean up
test yes != "$flush" || {
  d=`basename $datadir`
  test \! -d $datadir || (set -x; rm -rf $datadir)
}

# Stop here after clean up when terminating a session
test yes != "$stop" || {
  exit
}

if [ yes = "$nohup" ]
then
  # Restore console after disabling ctrl-C for nimbus
  stty_save=`stty --save </dev/tty`
else
  # Set logging unless deamon enabled
  logs=yes
fi

# Start a new nimbus session in the background
test yes != "$start" || (
  mkdir -p $datadir/log $datadir/data

  nimbus=`find_exe nimbus $find_nimbus`
  genesis=`find_file $genesis_json $find_genesis`
  bootstrap=`find_file $bootstrap_txt $find_bootstrap`

  test yes != "$nohup" || {
     trap "echo '*** $self: NOHUP ignored'" HUP
     trap "echo '*** $self: terminating ..';exit"  INT TERM QUIT
     stty intr "" </dev/tty
  }
  (
    cd $datadir

    mv ./log/config ./log/config~ 2>/dev/null || true
    {
       echo s$logfile_max
       echo n$num_backlogs
    } >./log/config

    set -x
    ${nimbus:-nimbus} \
      --data-dir:./data \
      --custom-network:"$genesis" \
      --bootstrap-file:"$bootstrap" \
      --terminal-total-difficulty:$ttd \
      --min-sync-peers:$min_peers \
      --tcp-port:$port \
      --prune-mode:full \
      --log-level:TRACE

  ) | stripColors | svlogd $datadir/log
) &

# After starting a session, make sure that svlogd is re-loaded in order
# to read the config file (woul not tdo it right on the start)
test yes != "$start" || {
    sleep 1
    pid=`get_pid_svlogd`
    test -z "$pid" || kill -HUP $pid
    echo
}

# Restore console after disabling ctrl-C for nimbus
test yes != "$nohup" || {
    stty $stty_save </dev/tty
}

# Logging ...
test yes != "$logs" || {
  mkdir -p $datadir/log/
  touch $datadir/log/current |
  tail -F $datadir/log/current |

    # Filter out chaff on console data
    grep -v \
      -e 'auth: ECIES encryption/decryption error' \
      -e 'Bonding to peer' \
      -e 'Connecting to node' \
      -e 'file=discovery.nim:' \
      -e 'file=kademlia.nim:' \
      -e 'Waiting for more peers' \
      -e '>>> [pf][io]' \
      -e '<<< [pf][io]'
}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
