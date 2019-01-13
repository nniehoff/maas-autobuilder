#!/bin/bash

source maas_env.sh

exec_cmd() {
    local title=$1
    shift
    if [ "$title" != "" ]; then
        echo $title
    fi

    "$@"
    local status=$?

    if [ $status -ne 0 ]; then
        echo "ERROR: $title command failed (RC: $status)"
        echo "ERROR: $title command failed (RC: $status)" >&2
        exit 1
    fi
}

maas_login() {


  # Create the initial 'admin' user of MAAS, purge first!
  echo "Getting Admin Key"
  if [ ! -f /root/.maas-api.key ]; then
    maas_api_key=`maas-region apikey --username=$maas_profile | tee ~/.maas-api.key`
    local status=$?

    if [ $status -ne 0 ]; then
        echo "ERROR: Getting Admin Key failed (RC: $status)"
        echo "ERROR: Getting Admin Key failed (RC: $status)" >&2
        exit 1
    fi
  else
    maas_api_key=`cat /root/.maas-api.key`
  fi

  # Fetch the MAAS API key, store to a file for later reuse, also set this var to that value
  exec_cmd "Logging in to MaaS" \
      maas login "$maas_profile" "$maas_endpoint" "$maas_api_key"
}

build_regiond() {
    # maas_endpoint=$(maas list | awk '{print $2}')
    KEYRING_FILE=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg

    if [ ! -f /root/.maas_admin_created ]; then
        exec_cmd "Creating Admin User" \
             maas createadmin --username "$maas_profile" --password "$maas_pass" \
            --email "$maas_profile"@"$maas_pass" --ssh-import lp:"$launchpad_user"

        touch /root/.maas_admin_created
    fi

    maas_login

    # Inject the maas SSH key
    #maas $maas_profile sshkeys create "key=$maas_ssh_key"

    # Update settings to match our needs
    exec_cmd "Disabling Network Discovery" \
        maas $maas_profile maas set-config name=network_discovery value=disabled
    exec_cmd "Setting Discovery Interval to 0" \
        maas $maas_profile maas set-config name=active_discovery_interval value=0
    exec_cmd "Setting MaaS Name" \
        maas $maas_profile maas set-config name=maas_name value=maas
    exec_cmd "Setting MaaS Upstream DNS" \
        maas $maas_profile maas set-config name=upstream_dns \
        value="$maas_upstream_dns"
    exec_cmd "Setting MaaS NTP Servers" \
        maas $maas_profile maas set-config name=ntp_servers \
        value="$maas_ntp_servers"
    exec_cmd "Disabling Analytics" \
        maas $maas_profile maas set-config name=enable_analytics value=false
    exec_cmd "Disabling HTTP Proxy" \
        maas $maas_profile maas set-config name=enable_http_proxy value=false
    exec_cmd "Disabling 3rd Party Drivers" \
        maas $maas_profile maas set-config name=enable_third_party_drivers \
        value=false
    exec_cmd "Disabling Secure Erase" \
        maas $maas_profile maas set-config name=disk_erase_with_secure_erase \
        value=false
    exec_cmd "Setting Image Repository" \
        maas $maas_profile boot-sources create url=$maas_images_mirror \
        keyring_filename=$KEYRING_FILE
    exec_cmd "Removing Default Image Repository" \
        maas $maas_profile boot-source delete 1
    exec_cmd "Forcing Local Mirror" \
        maas $maas_profile package-repository update 1 \
        url=$ubuntu_packages_mirror
    
    touch /root/.maas_regiond_built
}


create_networks() {

    exec_cmd "Renaming Default Fabric" \
        maas $maas_profile fabric update 0 name=TaggedMaaSNet
    echo "Getting Existing Fabrics"
    EXISTING_FABRICS=`exec_cmd "" \
        maas $maas_profile fabrics read`
    echo "Searching for Existing Fabrics"
    EXISTING_FABRIC_ID=`exec_cmd "" \
        echo $EXISTING_FABRICS | jq -r --arg name UntaggedMaaSNet \
        '.[] | select(.name == $name) | .id'`

    # Update or Create Fabric
    if [ "$EXISTING_FABRIC_ID" ]; then
        exec_cmd "Updating Fabric" \
            maas $maas_profile fabric update $EXISTING_FABRIC_ID \
            name=UntaggedMaaSNet

        NEW_FABRIC_ID=$EXISTING_FABRIC_ID
    else
        echo "Creating New Fabric"
        NEW_FABRIC_JSON=`exec_cmd "" \
            maas $maas_profile fabrics create name=UntaggedMaaSNet`
        echo "Getting New Fabric ID"
        NEW_FABRIC_ID=`exec_cmd "" \
            echo $NEW_FABRIC_JSON | jq -r '.id'`
    fi
    echo "Getting Existing VLANs"
    EXISTING_VLANS=`exec_cmd "" \
        maas $maas_profile vlans read $NEW_FABRIC_ID`
    echo "Getting Exisiting Spaces"
    EXISTING_SPACES=`exec_cmd "" \
        maas $maas_profile spaces read`
    echo "Getting Existing Subnets"
    EXISTING_SUBNETS=`exec_cmd "" maas $maas_profile subnets read`

    for NETB64 in `cat networks.json | jq -rc '.[] | @base64'`; do
        NETWORK_JSON=`echo $NETB64 | base64 --decode`
        VLANNAME=`echo $NETWORK_JSON | jq -r '.name'`
        VLANID=`echo $NETWORK_JSON | jq -r '.vid'`
        CIDR=`echo $NETWORK_JSON | jq -r '.cidr'`
        GATEWAY=`echo $NETWORK_JSON | jq -r '.gateway'`
        DHCP_ENABLED=`echo $NETWORK_JSON | jq -r '.dhcp_on'`
        DHCP_START=`echo $NETWORK_JSON | jq -r '.dhcp_start'`
        DHCP_END=`echo $NETWORK_JSON | jq -r '.dhcp_end'`

        echo "Searching for Existing Space"
        EXISTING_SPACE_ID=`exec_cmd "" \
            echo $EXISTING_SPACES | jq -r --arg name "Space-${VLANNAME}" \
            '.[] | select(.name == $name) | .id'`

        # Create the space if it doesn't exist
        if [ ! "$EXISTING_SPACE_ID" ]; then
            exec_cmd "Creating Space Space-${VLANNAME}" \
                maas $maas_profile spaces create name=Space-${VLANNAME}
        fi

        echo "Searching for Existing VLAN"
        EXISTING_VLAN_ID=`exec_cmd "" \
            echo $EXISTING_VLANS | jq -r --argjson id $VLANID \
            '.[] | select(.vid == $id) | .id '`

        # Update the existing VLAN or create a new one
        if [ "$EXISTING_VLAN_ID" ]; then
            exec_cmd "Updating VLAN ${VLANID} (${VLANNAME})" \
                maas $maas_profile vlan update $NEW_FABRIC_ID $VLANID \
                name=VLAN-$VLANNAME space=Space-${VLANNAME}

            NEW_VLAN_ID=$EXISTING_VLAN_ID
        else
            echo "Creating VLAN ${VLANID} (${VLANNAME})"
            NEW_VLAN_JSON=`exec_cmd "" maas $maas_profile vlans create \
                $NEW_FABRIC_ID name=VLAN-$VLANNAME vid=${VLANID} \
                space=Space-${VLANNAME}`
        
            echo "Getting New VLAN ID"
            NEW_VLAN_ID=`exec_cmd "" echo $NEW_VLAN_JSON | jq -r '.id'`
        fi

        # In MaaS 2.4 the .vlan.id is correct but in 2.3 it is incorrect 
        # so we handle that by a second search
        echo "Searching for Existing Subnet"
        EXISTING_SUBNET_ID=`exec_cmd "" \
            echo $EXISTING_SUBNETS  | jq -r --arg cidr $CIDR --argjson vlanid \
            $NEW_VLAN_ID \
            '.[] | select(.cidr == $cidr and .vlan.id == $vlanid) |.id'`

        if [ ! "$EXISTING_SUBNET_ID" ]; then
          EXISTING_SUBNET_ID=`exec_cmd "" \
            echo $EXISTING_SUBNETS  | jq -r --arg cidr $CIDR \
            '.[] | select(.cidr == $cidr) |.id'`
        fi

        # Update the Existing Subnet or Create a new one
        if [ "$EXISTING_SUBNET_ID" ]; then
            exec_cmd "Updating Subnet Subnet-${VLANNAME}" \
                maas $maas_profile subnet update $EXISTING_SUBNET_ID \
                name=Subnet-${VLANNAME} gateway_ip=${GATEWAY} \
                dns_servers="$maas_upstream_dns"
        else
            exec_cmd "Creating Subnet Subnet-${VLANNAME}" \
                maas $maas_profile subnets create name=Subnet-${VLANNAME} \
                cidr=${CIDR} gateway_ip=${GATEWAY} \
                dns_servers="$maas_upstream_dns" vlan=$NEW_VLAN_ID
        fi
   done
   touch /root/.maas_networks_created
}

configure_dhcp() {
    MAAS_FABRIC_UNTAGGEDNET_ID=`maas $maas_profile fabrics read | \
      jq '.[] | select(.name  == "UntaggedMaaSNet") | .id'`

    for NETB64 in `cat networks.json | jq -rc '.[] | @base64'`; do
        NETWORK_JSON=`echo $NETB64 | base64 --decode`
        VLANNAME=`echo $NETWORK_JSON | jq -r '.name'`
        VLANID=`echo $NETWORK_JSON | jq -r '.vid'`
        CIDR=`echo $NETWORK_JSON | jq -r '.cidr'`
        GATEWAY=`echo $NETWORK_JSON | jq -r '.gateway'`
        DHCP_ENABLED=`echo $NETWORK_JSON | jq -r '.dhcp_on'`
        DHCP_START=`echo $NETWORK_JSON | jq -r '.dhcp_start'`
        DHCP_END=`echo $NETWORK_JSON | jq -r '.dhcp_end'`
        
        if [ "$DHCP_ENABLED" == "true" ]; then
            exec_cmd "Creating IP Range on Subnet-${VLANNAME}" \
                maas $maas_profile ipranges create type=dynamic \
                start_ip=$DHCP_START end_ip=$DHCP_END

            echo "Getting MaaS Rack Controller ID"
            RACK_CONTROLLER_ID=`exec_cmd "" maas $maas_profile rack-controllers read | \
              jq -r --arg cidr $CIDR \
              '.[] as $parent | .[].interface_set | .[].links | .[].subnet | select(.cidr == $cidr) | $parent.system_id'`

            # This must not be MaaS 2.4 so we are guessing there is only 1 rack
            if [ ! "$RACK_CONTROLLER_ID" ]; then
              RACK_CONTROLLER_ID=`exec_cmd "" maas $maas_profile rack-controllers read | \
                jq -r '.[].system_id'`
            fi

            if [ $? -ne 0 ]; then
                echo "ERROR: Getting Rack System ID failed (RC: $status)"
                echo "ERROR: Getting Rack System ID failed (RC: $status)" >&2
                exit 1
            fi

            exec_cmd "Enabling DHCP On VLAN-${VLANNAME} (${VLANID})" \
                maas $maas_profile vlan update $MAAS_FABRIC_UNTAGGEDNET_ID \
                $VLANID dhcp_on=True primary_rack=$RACK_CONTROLLER_ID
        fi
    done                                 

    touch /root/.maas_dhcp_configured

    # This is needed, because it points to localhost by default and will fail to
    # commission/deploy in this state
    # sudo maas-rack config --region-url "http://$maas_bridge_ip:5240/MAAS/" && sudo service maas-rackd restart
}

add_chassis() {
  for VIRB64 in `cat virsh_hosts.json | jq -rc '.[] | @base64'`; do
    VIRSH_JSON=`echo $VIRB64 | base64 --decode`
    VIRSH_NAME=`echo $VIRSH_JSON | jq -r '.name'`
    VIRSH_IP=`echo $VIRSH_JSON | jq -r '.ip'`
    VIRSH_CHASSIS="qemu+ssh://${virsh_user}@${VIRSH_IP}/system"

    exec_cmd "Adding Chassis $VIRSH_NAME" \
      maas $maas_profile machines add-chassis chassis_type=virsh \
      prefix_filter=maas-node hostname="$VIRSH_CHASSIS"
  done

  MAAS_MACHINES=`exec_cmd "" maas $maas_profile machines read | jq '.[]'`
  EXISTING_TAGS=`exec_cmd "" maas $maas_profile tags read`

  # Create Tags based on parameters from tags.json
  for TAGB64 in `cat tags.json | jq -rc '.[] | @base64'`; do
    TAG_JSON=`echo $TAGB64 | base64 --decode`
    TAG_NAME=`echo $TAG_JSON | jq -r '.name'`
    TAG_DESCRIPTION=`echo $TAG_JSON | jq -r '.description'`
    TAG_PATTERN=`echo $TAG_JSON | jq -r '.hostname_pattern'`

    EXISTING_TAG=`echo $EXISTING_TAGS | jq -r --arg name $TAG_NAME \
        '.[] | select(.name == $name) |.name'`

    # Update tag or create new one
    if [ "$EXISTING_TAG" ]; then
        exec_cmd "Updating Tag $TAG_NAME" maas $maas_profile tag update \
            $TAG_NAME comment="$TAG_DESCRIPTION"
    else
        exec_cmd "Creating Tag $TAG_NAME" maas $maas_profile tags create \
            name="$TAG_NAME" comment="$TAG_DESCRIPTION"
    fi

    # Match machines hostnames based on regex from tags.json
    APPLICABLE_MACHINES=`echo $MAAS_MACHINES | jq -r --arg regex $TAG_PATTERN \
        '. as $parent | .hostname | select(test($regex)) | $parent.system_id'`

    ADD_STRING=`echo $APPLICABLE_MACHINES | sed 's@ @ add=@g'`
    exec_cmd "Applying Tag $TAG_NAME" maas $maas_profile tag update-nodes \
        $TAG_NAME add=$ADD_STRING
  done

  touch /root/.maas_chassis_added
}

import_images() {
    echo "Importing boot images, please be patient, this may take some time..."
    maas $maas_profile boot-resources import

    until [ "$(maas $maas_profile boot-resources is-importing)" = false ]; do sleep 3; done;
}

remove_maas() {
    # Drop the MAAS db ("maasdb"), so we don't risk reusing it
    sudo -u postgres psql -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='maasdb'"
    sudo -u postgres psql -c "drop database maasdb"

    # Remove everything, start clean and clear from the top
    DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge \
        "${maas_packages[@]}" "${pg_packages[@]}" && \
        sudo apt-get -fuy autoremove

    # Yes, they're removed but we want them PURGED, so this becomes idempotent
    for package in "${maas_packages[@]}" "${pg_packages[@]}"; do
       sudo dpkg -P "$package"
    done
}

install_maas() {
    # This is separate from the removal, so we can handle them atomically
    # sudo apt -fuy --reinstall install maas maas-cli jq tinyproxy htop
    # vim-common
    sudo apt -fuy --reinstall install "${maas_packages[@]}" "${pg_packages[@]}"
}

show_help() {
  echo "

  -a <cloud_name>    Do EVERYTHING (maas, juju cloud, juju bootstrap)
  -b                 Build out and bootstrap a new MAAS
  -c <cloud_name>    Add a new cloud + credentials
  -i                 Just install the dependencies and exit
  -j <name>          Bootstrap the Juju controller called <name>
  -n                 Create MAAS kvm nodes (to be imported into chassis)
  -r                 Remove the entire MAAS server + dependencies
  -t <cloud_name>    Tear down the cloud named <cloud_name>
  "
}

if [ $# -eq 0 ]; then
  printf "%s needs options to function correctly. Valid options are:" "$0"
  show_help
  exit 0
fi

while getopts ":a:bcinrdm" opt; do
  case $opt in
   b )
      echo "Building out a new MAAS server"
      build_regiond
      exit 0
    ;;
   n )
       echo "Creating Networks"
       maas_login
       create_networks
       exit 0
    ;;
   i )
      echo "Installing MAAS and PostgreSQL dependencies"
      install_maas
      exit 0
    ;;
   r )
      remove_maas
      exit 0
    ;;
   d )
      maas_login
      configure_dhcp
      exit 0
    ;;
   c )
      maas_login
      add_chassis
      exit 0
    ;;
   m )
      maas_login
      import_images
      exit 0
    ;;
  \? )
      printf "Unrecognized option: -%s. Valid options are:" "$OPTARG" >&2
      show_help
      exit 1
    ;;
    : )
      printf "Option -%s needs an argument.\n" "$OPTARG" >&2
      show_help
      echo ""
      exit 1
    ;;
  esac
done

  
