# Blacklist the IP addresses from the file filteredheavyusers.txt in iptables

while read in; do

     sudo iptables -I INPUT 5 -p tcp --dport 12865 -j DROPPEDNETPERF --src "$in";

done < filteredheavyusers.txt

# and save the iptables config over reboots...

sudo su -c 'iptables-save  > /etc/iptables/rules.v4' # must be root...
sudo su -c 'ip6tables-save > /etc/iptables/rules.v6'
