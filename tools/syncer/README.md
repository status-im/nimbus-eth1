Setting up a routing tunnel from a hidden Rfc 1918 network
==========================================================

Routing bidirectional traffic selectively through a dedicated tunnel to a
public server (e.g. a non-expensive rented *cloud* system) can emulate many
properties of a publicly exposed system. This can be used for a test system
hidden behind a digital subscriber-line or dial-up network so it can emulate
many properties of a publicly exposed system.

The systems involved do typically share other services besides the ones
installed for tunnelling. Some care must be taken on the local system when
allowing incoming data connections. This can be mitigated by using network
filters (e.g. `nftables` on *Linux*) for accepting incoming connections only
on sub-systems, e.g. `qemu` or `docker` virtual hosts.

General layout
--------------

The following scenario was set up for testing the syncer

                EXTERN                 LOCAL              SUB1
               +-------+              +-------+           +------+
               |       |    tunnel    |       |           |      |
               |     o---l----------r---o   o---s---+---a---o    |
               |   o   |              |       |     |     |      |
               +---|---+              +---|---+     |     +------+
                   x                      y         |
                   |                      |         |      SUB2
         ----//----+----//------------//--+         |     +------+
          internet   internet    MASQUERADE         |     |      |
                                                    +---b---o    |
                                                    |     |      |
                                                    |     +------+
                                                    :     ...

where *EXTERN* is a system with a public IP address (on interface **x**),
fully exposed to the internet (e.g. a rented *cloud* server). *LOCAL* is a
system on a local network (typically with Rfc 1918 or Rfc 5737 addresses)
and has access to the internet via *SNAT* or *MASQUERADE* address translation
techniques on interface **y**.

The system *LOCAL* accesses services on system *EXTERN* via the internet
connection. An *EXTERN* -- *LOCAL* logical connection facilitated by
interfaces **X** and **Y** allows for setting up a virtual peer-to-peer
tunnel for general IP (UDP and TCP needed) between both systems. This tunnel
is depicted above the dedicated *EXTERN* -- *LOCAL* connection with
interfaces **l** and **r**.

The system *LOCAL* provides routing services to the internet for systems
*SUB1*, *SUB2*, etc. via interface **s** on *LOCAL*. Technically, these
sub-systems might run on a virtual system within the *LOCAL* system.


Example interface and network addresses
---------------------------------------

These addresses as used the below configuration scripts are listed here.

| interface | IP address       | netmask | gateway       | additional info
|-----------| ----------------:|:--------|:--------------|-----------------
|   **a**   |   192.168.122.22 | /24     | 192.168.122.1 |
|   **b**   |   192.168.122.23 | /24     | 192.168.122.1 |
|   **l**   |         10.3.4.1 | /32     | n/a           | point-to-point
|   **r**   |         10.3.4.2 | /32     | n/a           | point-to-point
|   **s**   |    192.168.122.1 | /24     |               |
|   **x**   | <server-address> |         |               | public address
|   **y**   |                  |         | 172.17.33.1   | dynamic, DHCP


Why not using *ssh* or any other TCP tunnel software
----------------------------------------------------

With *ssh*, one can logically pre-allocate a list of TCP connections between
two systems. This sets up listeners on the one end of the tunnel and comes out
on the other end when an application is connecting to a listener. It is most
easily set up and provides reliable, encrypted connections. But this does not
the tunnel wanted here.

In another *ssh* mode, one can build a connection and tie it to a *pty* or
a *tun* device. In the case of a *pty*, one can install a *ppp* connection
on top of that. In either case, one ends up with a pair of network interfaces
that could be used for implementing the **r**--**l** tunnel for the above
scenario.

Unfortunately, that scenario works only well in some rare cases (probably on
a *LAN*) for TCP over *ssh*, the reason being that TCP traffic control will
adjust simultaneously: the outer *ssh* TCP connection and the inner TCP data
connection (see details on
[PPP over *ssh*](https://web.archive.org/web/20220103191127/http://sites.inka.de/bigred/devel/tcp-tcp.html)
or [TCP over TCP](https://lsnl.jp/~ohsaki/papers/Honda05_ITCom.pdf).)


Suitable **r**--**l** tunnel software solutions
-----------------------------------------------

The software package used here is `quicktun` which runs a single UDP based
peer-to-peer tunnel and provides several flavours of encryption.

Other solutions would be `openVPN` which provides multiple topologies with
pluggable authentication and encryption, or `vtun` which provides a server
centric star topology (with optional encryption considered weak.)


Setting up the **r**--**l** tunnel on Debian bookworm
-----------------------------------------------------

A detailed description on the `quicktun` software is available at
[QuickTun](http://wiki.ucis.nl/QuickTun).

All command line commands displayed here must be run with administrator
privileges, i.e. as user **root**.

Install tunnel software on *LOCAl* and *EXTERN* via

        apt install quicktun

Generate and remember two key pairs using `keypair` twice. This gives keys

        SECRET: <local-secret>
        PUBLIC: <local-public>

        SECRET: <extern-secret>
        PUBLIC: <extern-public>

On *LOCAL* set it up as client. Install the file

         /etc/network/interfaces.d/client-tun

with contents

         # Do not use the automatic directive "auto tun0" here. This would take
         # up this tunnel interface too early. Rather use `ifup tun0` in
         # "/etc/rc.local". On Debian unless done so, this start up file can
         # be enabled via
         #   chmod +x /etc/rc.local
         #   systemctl enable rc-local.service
         #
         iface tun0 inet static
           # See http://wiki.ucis.nl/QuickTun for details. Contrary to the
           # examples there, comments must not follow the directives on the
           # same line to the right.
           address 10.3.4.2
           pointopoint 10.3.4.1
           netmask 255.255.255.255
           qt_local_address 0.0.0.0

           # Explicit port number (default 2998)
           qt_remote_port 2992
           qt_remote_address <server-address>

           # Available protocols: raw, nacl0, nacltai, salty
           qt_protocol nacl0
           qt_tun_mode 1

           # This is the private tunnel key which should be accessible by
           # root only. Public access to this config file should be resticted
           # to root only, e.g. via
           #   chmod go-rw <this-file>
           qt_private_key <local-secret>

           # Server public key
           qt_public_key <extern-public>

           # Make certain that tunnel packets can be sent via outbound
           # interface.
           up route add -host <server-address> gw 172.17.33.1 || true
           down route del -host <server-address> gw 172.17.33.1 || true

           # Route virtual network data into the tunnel. To achieve this, two
           # routing tables are used: "main" and a local one "8". The "main"
           # table is the standard table, the local one "8" is used to route
           # a set of traffic into the tunnel interface. Routing tables "main"
           # or "8" are selected by the policy set up via
           # "ip rules add ... lookup <table>"
           up ip rule add from 192.168.122.1 lookup main || true
           up ip rule add from 192.168.122.0/24 lookup 8 || true
           up ip rule add from 10.3.4.2 lookup 8 || true
           up ip route add default via 10.3.4.1 table 8 || true
           up ip route add 192.168.122.0/24 via 192.168.122.1 table 8 || true

           down ip rule del from 192.168.122.1 lookup main || true
           down ip rule del from 192.168.122.0/24 || true
           down ip rule del from 10.3.4.2 lookup 8 || true
           down ip route flush table 8 || true

         # End

and on *EXTERN* set it up as server. Install the file

         /etc/network/interfaces.d/server-tun

with contents

         iface tun0 inet static
           address 10.3.4.1
           pointopoint 10.3.4.2
           netmask 255.255.255.255
           qt_remote_address 0.0.0.0

           qt_local_port 2992
           qt_local_address <server-address>

           qt_protocol nacl0
           qt_tun_mode 1

           # Do not forget to run `chmod go-rw <this-file>
           qt_private_key <extern-secret>
           qt_public_key <local-public>

           # Route into hidden sub-network which will be exposed after NAT.
           up route add -net 192.168.122.0 netmask 255.255.255.0 gw 10.3.4.1
           down route del -net 192.168.122.0 netmask 255.255.255.0 gw 10.3.4.1

On either system *EXTERN* and *LOCAL* make certain that the file

         /etc/network/interfaces

contains a line

         source /etc/network/interfaces.d/*

Then the tunnel can be established by running

         ifup tun0

on either system. In order to verify, try running

         ping 10.3.4.2   # on EXTERN
         ping 10.3.4.1   # on LOCAL


Configuring `iptables` on the *EXTERN* server
---------------------------------------------

As a suggestion for an `nftables` filter and NAT rules set on a *Linux* host
*EXTERN* would be

         #! /usr/sbin/nft -f

         define wan_if   = <server-interface>
         define wan_ip   = <server-address>
         define tun_if   = tun0

         define gw_ip    = 10.3.4.2
         define gw_ports = { 30600-30699, 9010-9019 }
         define h1_ip    = 192.168.122.22
         define h1_ports = 30700-30799
         define h2_ip    = 192.168.122.23
         define h2_ports = 9000-9009

         table ip filter {
           # Accept all input and output
           chain INPUT { type filter hook input priority filter; policy accept; }
           chain OUTPUT { type filter hook output priority filter; policy accept; }

           # Selective tunnel transit and NAT debris
           chain FORWARD {
             type filter hook forward priority filter; policy drop;
             ct state related,established counter accept
             iif $tun_if ct state new counter accept
             iif $tun_if counter accept
             iif $wan_if ct state new counter accept
             iif $wan_if counter accept
             counter log prefix "Tunnel Drop " level info
             counter drop
           }
         }
         table ip nat {
           chain INPUT { type nat hook input priority 100; policy accept; }
           chain OUTPUT { type nat hook output priority -100; policy accept; }

           # Map new connection destination address depending on dest. port
           chain PREROUTING {
             type nat hook prerouting priority dstnat; policy accept;
             ip daddr $wan_ip tcp dport $h1_ports counter dnat to $h1_ip
             ip daddr $wan_ip udp dport $h1_ports counter dnat to $h1_ip
             ip daddr $wan_ip tcp dport $h2_ports counter dnat to $h2_ip
             ip daddr $wan_ip udp dport $h2_ports counter dnat to $h2_ip
             ip daddr $wan_ip tcp dport $gw_ports counter dnat to $gw_ip
             ip daddr $wan_ip udp dport $gw_ports counter dnat to $gw_ip
           }
           # Map new connection source address to wan address
           chain POSTROUTING {
             type nat hook postrouting priority srcnat; policy accept;
             oif $wan_if ip daddr $wan_ip counter return
             oif $wan_if ip saddr $gw_ip counter snat to $wan_ip
             oif $wan_if ip saddr $h1_ip counter snat to $wan_ip
             oif $wan_if ip saddr $h2_ip counter snat to $wan_ip
           }
         }


Running Nimbus EL or CL on *LOCAL* client and/or *SUB1*. *SUB2*
---------------------------------------------------------------

When starting `nimbus_execution_client` on *SUB1*, *SUB2*, etc. systems,
one needs to set options

         --engine-api-address=0.0.0.0
         --nat=extip:<server-address>

and for the `nimbus_beacon_node` on *SUB1*, *SUB2*, etc. use

         --nat=extip:<server-address>

For running both, `nimbus_execution_client` and `nimbus_beacon_node`
on *LOCAL* directly, one needs to set options

         --listen-address=10.3.4.2
         --nat=extip:<server-address>

on either system.
