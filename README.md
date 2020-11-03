# README for running a netperf server

It's easy to run a netperf server.
Just stand up a VPS,
[download the netperf zip from https://github.com/HewlettPackard/netperf](https://github.com/HewlettPackard/netperf),
`make; make install; netserver &`,
open port 12865 on the firewall,
and you're on the air.
BUT...

A netperf server (for example, at [netperf.bufferbloat.net](http://netperf.bufferbloat.net)) is an attractive nuisance.
A garden-variety VPS can easily handle the load generated by a handful of network researchers.
But it has grown popular with people who want to test their network connection every five minutes, 24x7.
This rapidly exhausts the bandwidth caps of (low-cost) hosting plans, leading to increased expense or suspension of the server.

This repository contains a number of tools for identifying and shutting down "abusers" who run bandwidth tests continually.
It does this by using `iptables` rules to identify traffic to port 12865 (the default netperf port), counting the connections, and blocking addresses that cross a threshold.

*Current Settings:* The threshold is set at 500 connections per 24-48 hour time interval.
This ballpark number was computed using the following factors: a normal "speed test" typically uses five simultaneous connections to "fill the pipe": first in the download phase then the upload phase.
Thus, a single speed test session creates 10 connections.
If the count exceeds the threshold (500),
it means that address has initiated about 50 speed tests over a 
day or two, so we stop accepting connections for that address.
The script currently runs every 30 minutes via a `cron` job.

**TL;DR** These settings seem to limit the total traffic to less than 4 TB/month (the limit on my cheap VPS server)
while not inconveniencing legitimate researchers or people tuning their home networks.

## The Details

`iptables` is configured to log a message with a prefix of "Incoming netperf" each time a connection to port 12865 arrives.
Log entries (written to `/var/log/kern.log`) have the form:

```
Feb 11 03:11:45 atl kernel: [9353834.165208] Incoming netperf IN=lo OUT= MAC=00:00:00:00:00:00:00:00:00:00:00:00:08:00 
SRC=23.x.x.x DST=23.x.x.x LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=38423 DF PROTO=TCP SPT=56374 DPT=12865 WINDOW=65535 RES=0x00 SYN 
URGP=0
```

The important scripts in this repo are:

* **listandblacklist.sh** runs via cron on a regular basis and emails its output for review.
This script calls each of the following scripts in sequence:

* **findunfiltered.sh ###** scans the `/var/log/kern.log*` files for those "Incoming 
netperf" lines,
isolates the SRC=... addresses, and creates a frequency count of those addresses. It writes a list of IP addresses
that occur more than the threshold  
to the `heavyusers.txt` file.

   The script then compares those new addresses (in `heavyusers.txt`) to the list of IP addresses that are already present in iptables with a DROPPEDNETPERF target
and writes new addresses to `filteredheavyusers.txt`

* **addtoblacklist.sh** reads `filteredheavyusers.txt` to update the `iptables` rules by adding each address to the INPUT chain with a -j DROPPEDNETPERF target.
The DROPPEDNETPERF chain drops the packet (and thus the connection.) 

## iptables setup   

First, (one time) add a rule to the INPUT chain to log each arriving netperf connection.
The command below appends (-A) to the INPUT chain a rule so that a TCP packet on port 12865 jumps to the LOG chain with the prefix "Incoming netperf "

```
sudo iptables -A INPUT -p tcp --dport 12865 -j LOG --log-prefix "Incoming netperf "
```
Second, (one time) create a DROPPEDNETPERF chain to process packets that exceed the threshold.
*Note:* Originally, this chain logged a "Dropped netperf" message (the second rule below), but it no longer does this.
That's because, under load, the logging messages for the high volume of dropped packets placed too much load on the server.
The commands to create the chain are:

```
sudo iptables -N DROPPEDNETPERF
# sudo iptables -A DROPPEDNETPERF -j LOG --log-prefix "Dropped netperf "
sudo iptables -A DROPPEDNETPERF -j DROP
```

Finally, the `addtoblacklist.sh` script adds an `iptables` rule to drop connections for the specified address:
insert (-I) a rule in the INPUT chain at position 3, with criteria for tcp and port 12865 and the specified source address.
A matching packet "jumps to" the DROPPEDNETPERF chain that subsequently drops the packet.
This prevents the connection from becoming established.

```
sudo iptables -I INPUT 3 -p tcp --dport 12865 -j DROPPEDNETPERF --src <ip-address>
```

The command above takes effect immediately.
If you wish the command to persist across reboots, you must use `iptables-save`, like this.
These commands must be run as root.

   ```
sudo su -c 'iptables-save  > /etc/iptables/rules.v4' 
sudo su -c 'ip6tables-save > /etc/iptables/rules.v6'
   ```
 
`iptables -nvL` displays counts of the number of packets and bytes processed by each of the `iptables` rules.

## Potential To-do's

The scripts currently work to my satisfaction, keeping total bandwidth per month to less than 4 TBytes.
I have had a few idle speculations for optimizations if needed:

1. I am told that `ipset` is a better way to match large numbers of IP addresses.
At the moment, my iptables list has about 800 addresses with no obvious effect on the server.
However, that list is growing by 10 devices per day (with an unknown upper bound),
so `ipset` may become necessary in the future.

2. There's another possibility for detecting abuse that I have not investigated.
To date, these scripts to not attempt to use any `iptables` rate limiting functions.
Normally, an address creeps up to the limit over time, then exceeds it and gets blacklisted.

  However, there have been occasions where the IP addresses have accumulated thousands (in one case, 14,000) of new connections between 30-minute runs of the cron job.
(This can be detected from the output of the `findunfilteredips.sh` script.
It displays two lists:
addresses that were just blocked because they exceeded the (500) connection threshold,
and a sorted list of 30 heavy addresses.)
Such a large jump is an obvious signal of abuse: it may be worth estimating the bandwidth consumed to see if it makes sense to find a way to use `iptables` connection rate limiting rules to detect and block the address earlier than the 30-minute test.

3. Current rules only block single IP addresses.
But a review of all addresses shows that there are obvious /24 or even /16 address ranges that maybe worth blocking.
(This suggests an organized attempt to run tests continually: when an address gets blocked, a different machine on the same subnet picks up heavy testing.)
Again, a review of the amount of the actual traffic involved could determine whether this effort was warranted.

4. There is no facility for automatically removing an address from the blacklist.
If someone writes to me and says their address seems to be blocked, I will simply remove their address from the rules.

## Old info - not necessarily up-to-date

Description of other files:

   * `countsofip.txt` - file that shows IP address counts in the form: ### 192.168.1.1
   * `heavyusers.txt` - IPs of devices with > *threshold* connections from log files
   * `whitelist.txt` - a file of IP addresses never to blacklist
   * `filteredheavyusers.txt` - heavy users not present in iptables
   * `iptables-addresses.txt` - addresses with DROPPEDNETPERF as the target in iptables
   * `iptables.txt` - raw output of 'iptables -nL'
   * `kernlog.txt` - concatenated output of all log files
   * `sh checkdistrib.sh <ipaddress>` - a script to display the number of tests for each one-hour interval for a specified address.
This indicates whether the device was continually testing, or tested for a while, then stopped, then started again.
   * `logscan.sh` precursor to findunfilteredips.sh. It scans the kern.log* files, and
shows counts for "Incoming" and "Dropped" netperf connections.

