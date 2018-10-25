#!/bin/bash

maas_profile=admin
virsh_user=nniehoff
maas_pass=openstack
launchpad_user=nniehoff
maas_upstream_dns="10.12.48.8 10.12.48.9"
maas_ntp_servers="${maas_upstream_dns}"
#maas_ssh_key=$(cat ~/.ssh/maas_rsa.pub)
maas_bridge_ip="$(ip addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1)"
maas_endpoint="http://$maas_bridge_ip:5240/MAAS"
maas_packages=(maas-region-controller maas-cli maas-proxy maas-region-api maas-common)
pg_packages=(postgresql postgresql-client postgresql-client-common postgresql-common)
