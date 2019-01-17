#!/bin/bash

maas_profile=admin
virsh_user=nniehoff
maas_pass=openstack
launchpad_user=nniehoff
maas_upstream_dns="10.12.48.8 10.12.48.9"
maas_ntp_servers="ntp1.home.nickniehoff.net ntp2.home.nickniehoff.net"
#maas_ssh_key=$(cat ~/.ssh/maas_rsa.pub)
maas_bridge_ip="$(ip a s eth0 | awk -F'[ /]' '/inet /{print $6}')"
maas_endpoint="http://$maas_bridge_ip:5240/MAAS"
maas_packages=(maas-region-controller maas-cli maas-proxy maas-region-api maas-common)
pg_packages=(postgresql postgresql-client postgresql-client-common postgresql-common)
maas_images_mirror=http://mirror.home.nickniehoff.net/maas/images/ephemeral-v3/daily/
ubuntu_packages_mirror=http://mirror.home.nickniehoff.net/ubuntu

