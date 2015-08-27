#!/usr/bin/env bash

NIXPKGS_GIT=git://github.com/nixos/nixpkgs.git
RACKSPACE_DISK=/dev/xvdb
RACKSPACE_PARTITION=/dev/xvdb1
RACKSPACE_FSTYPE=ext4
RACKSPACE_LABEL=nixos
RACKSPACE_HOST=

## -----------------------------------------------------------------------------
## -- Rackspace API wrapper

RACKSPACE_LOGIN_ACCOUNT=
RACKSPACE_API_LOGIN_TOKEN=
RACKSPACE_API_REGION="dfw"

RACKSPACE_SERVER_IP=
RACKSPACE_SERVER_PASS=
RACKSPACE_SERVER_ID=
RACKSPACE_SERVER_NAME=

function rackspace_login {
  RACKSPACE_API_LOGIN_TOKEN=$(curl -s -H 'Content-Type: application/json' -d \
"{ \"auth\":
    { \"RAX-KSKEY:apiKeyCredentials\":
      { \"username\": \"$RACKSPACE_LOGIN_USERNAME\",
        \"apiKey\":   \"$RACKSPACE_LOGIN_APIKEY\" } } }" \
'https://identity.api.rackspacecloud.com/v2.0/tokens' | jq -r ".access.token.id")

  RACKSPACE_LOGIN_ACCOUNT=$(curl -s -H 'Content-Type: application/json' -d \
"{ \"auth\":
    { \"RAX-KSKEY:apiKeyCredentials\":
      { \"username\": \"$RACKSPACE_LOGIN_USERNAME\",
        \"apiKey\":   \"$RACKSPACE_LOGIN_APIKEY\" } } }" \
'https://identity.api.rackspacecloud.com/v2.0/tokens' | jq -r ".access.token.tenant.id")

}

function rackspace_list_servers_json {
  rackspace_login

  RESULT=$(curl -s https://$RACKSPACE_API_REGION.servers.api.rackspacecloud.com/v2/$RACKSPACE_LOGIN_ACCOUNT/servers \
    -H "X-Auth-Token: $RACKSPACE_API_LOGIN_TOKEN" \
    | jq -r '.servers[] | select (.name[0:8] == "athena--")')
  IDS=$(echo "$RESULT" | jq -r '.id')

  RESULT=
  for x in $IDS; do
    INFO=$(curl -s https://$RACKSPACE_API_REGION.servers.api.rackspacecloud.com/v2/$RACKSPACE_LOGIN_ACCOUNT/servers/$x \
      -H "X-Auth-Token: $RACKSPACE_API_LOGIN_TOKEN" \
      | jq -r '. | .server.name, .server.accessIPv4')
    NAME=$(echo "$INFO" | head -1 | cut -c 9-)
    IP=$(echo "$INFO" | tail -1)
    RESULT+="{ \"name\": \"$NAME\", \"ip\": \"$IP\" }"
  done

  RESULT=$(echo "$RESULT" | sort |  jq '.')
  echo "$RESULT"
}

function rackspace_list_servers {
  rackspace_login

  RESULT=$(rackspace_list_servers_json)
  RESULT=$(echo "$RESULT" | jq -r '. | .name, .ip')

  # Column-ify output with a magic spell
  (echo "NAME_IP ADDRESS"; \
   echo "$RESULT" | while read line1; do \
     read line2; \
     echo "$line1"_"$line2"; \
   done | sort) | column -s'_' -t
}

function rackspace_wait_for_status { # $1 = server id; $2 = status; $3 = timeout
  SERVER_ID=$1
  WANTED_STATUS=$2

  DONE="0"
  TOTAL=0
  while [ ! "$DONE" = "1" ]; do
    STATUS=$(curl -s https://$RACKSPACE_API_REGION.servers.api.rackspacecloud.com/v2/$RACKSPACE_LOGIN_ACCOUNT/servers/$SERVER_ID \
      -H "X-Auth-Token: $RACKSPACE_API_LOGIN_TOKEN" | jq -r '.server.status')

    if [[ "$TOTAL" -ge "$3" ]]; then
      log_warning "Server is not in ACTIVE state after 5 minutes; may not be able to log in...";
      DONE="1"
    fi

    if [ "$STATUS" = "$WANTED_STATUS" ]; then
      DONE="1"
    fi

    sleep 5
    TOTAL=$(($TOTAL + 5))
  done
}

function rackspace_create_server { # $1 = server name
  rackspace_login

  log "Booting up a new Rackspace server '$1'..."
  # Note that it is extremely fucking important for some reason that
  # we use the Debian 7 Wheezy PVHVM image, since apparently using
  # other ones can randomly cause images to not boot. Hooray!
  IMAGE_ID=$(curl -s https://$RACKSPACE_API_REGION.servers.api.rackspacecloud.com/v2/$RACKSPACE_LOGIN_ACCOUNT/images \
    -H "X-Auth-Token: $RACKSPACE_API_LOGIN_TOKEN" \
    -H 'Content-Type: application/json' | jq -r '.images[] | select (.name == "Debian 7 (Wheezy) (PVHVM)") | .id')

  # Create the server
  SERVER_ID=$(curl -s https://$RACKSPACE_API_REGION.servers.api.rackspacecloud.com/v2/$RACKSPACE_LOGIN_ACCOUNT/servers \
    -H "X-Auth-Token: $RACKSPACE_API_LOGIN_TOKEN" \
    -H 'Content-Type: application/json' \
    -d \
"{ \"server\":
    { \"name\":      \"athena--$1\",
      \"imageRef\":  \"$IMAGE_ID\",
      \"flavorRef\": \"general1-1\" } }" | jq -r '.server.id')

  # Wait for the server to start
  log "Created server: $1 ($SERVER_ID)"
  log "Now waiting for server to finish building (for 5 minutes)..."
  rackspace_wait_for_status $SERVER_ID "ACTIVE" 300

  IP_ADDR=$(curl -s https://$RACKSPACE_API_REGION.servers.api.rackspacecloud.com/v2/$RACKSPACE_LOGIN_ACCOUNT/servers/$SERVER_ID \
      -H "X-Auth-Token: $RACKSPACE_API_LOGIN_TOKEN" | jq -r '.server.addresses.public[] | select (.version == 4) | .addr')
  log "Server up ($IP_ADDR); now waiting for rescue mode (for 10 minutes)..."

  # Put it into rescue mode
  ADMIN_PASS=$(curl -s https://$RACKSPACE_API_REGION.servers.api.rackspacecloud.com/v2/$RACKSPACE_LOGIN_ACCOUNT/servers/$SERVER_ID/action \
      -H 'Content-Type: application/json' \
      -H "X-Auth-Token: $RACKSPACE_API_LOGIN_TOKEN" \
      -d '{ "rescue": "none" }' | jq -r '.adminPass')
  rackspace_wait_for_status $SERVER_ID "RESCUE" 600

  log "OK, server entered rescue mode!"
  RACKSPACE_SERVER_IP=$IP_ADDR
  RACKSPACE_SERVER_PASS=$ADMIN_PASS
  RACKSPACE_SERVER_ID=$SERVER_ID
}

# Reboot server and return from rescue mode
function rackspace_unrescue_server {
  rackspace_login

  # Recover from rescue mode
  curl -s https://$RACKSPACE_API_REGION.servers.api.rackspacecloud.com/v2/$RACKSPACE_LOGIN_ACCOUNT/servers/$RACKSPACE_SERVER_ID/action \
      -H 'Content-Type: application/json' \
      -H "X-Auth-Token: $RACKSPACE_API_LOGIN_TOKEN" \
      -d '{ "unrescue": null }'
  rackspace_wait_for_status $SERVER_ID "ACTIVE" 600
}

## -----------------------------------------------------------------------------
## -- NixOS configuration template

RACKSPACE_NIXCFG=$(cat <<EOF
{ config, pkgs, ... }:

{
  boot.loader.grub.device  = "$RACKSPACE_DISK";

  networking.interfaces.eth0.ipAddress    = "IPV4ADDR1";
  networking.interfaces.eth0.prefixLength = 24;

  networking.interfaces.eth1.ipAddress    = "IPV4ADDR2";
  networking.interfaces.eth1.prefixLength = 19;

  networking.defaultGateway  = "GATEWAY";
  networking.nameservers     = [ "NAMESERVER1" "NAMESERVER2" ];

  networking.extraHosts = builtins.readFile ./athena-hosts;
}
EOF
)

## -----------------------------------------------------------------------------
## -- Setup steps

function rackspace_setup_tools {
  log "Installing needed packages and temporary users..."

  CMD=$(cat <<EOF
(apt-get update                            && \
 apt-get install bzip2 git -y              && \
 addgroup nixbld                           && \
 ((echo; echo; echo; echo; echo; echo) | adduser --disabled-password nixbld0) && \
 usermod -a -G nixbld nixbld0
) >/dev/null 2>&1
EOF
)

  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"
}

function rackspace_partition_disk {
  log "Formatting disk ($RACKSPACE_DISK)..."

  CMD=$(cat <<EOF
((echo d; echo w)                         | fdisk $RACKSPACE_DISK && \
 (echo n; echo; echo; echo; echo; echo w) | fdisk $RACKSPACE_DISK
) >/dev/null 2>&1
EOF
)

  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"
}

function rackspace_format_disk {
  log "Formatting '$RACKSPACE_PARTITION' as $RACKSPACE_FSTYPE (name='$RACKSPACE_LABEL')"

  CMD=$(cat <<EOF
(mkfs.$RACKSPACE_FSTYPE $RACKSPACE_PARTITION -L $RACKSPACE_LABEL && \
 mount $RACKSPACE_PARTITION /mnt                                 && \
 mkdir /mnt/boot /mnt/root
) >/dev/null 2>&1
EOF
)

  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"
}

function rackspace_install_nixpkgs {
  log "Installing nixpkgs..."

  CMD=$(cat <<EOF
(curl -s -o install-nix.sh https://nixos.org/nix/install && \
 bash ./install-nix.sh                                   && \
 rm -f ./install-nix.sh
) >/dev/null 2>&1
EOF
)

  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"
}

function rackspace_update_nixpkgs {
  log "Updating channels..."

  CMD=$(cat <<EOF
(. /root/.nix-profile/etc/profile.d/nix.sh                        && \
 nix-channel --remove nixpkgs                                     && \
 nix-channel --add http://nixos.org/channels/nixos-unstable nixos && \
 nix-channel --update
) >/dev/null 2>&1
EOF
)

  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"
}

function rackspace_bootstrap_nixos_tools {
  log "Installing NixOS utilities..."

  CMD=$(cat <<EOF
(. /root/.nix-profile/etc/profile.d/nix.sh                              && \
 export NIX_PATH=nixpkgs=/root/.nix-defexpr/channels/nixos:nixos=/root/.nix-defexpr/channels/nixos/nixos && \
 export NIXOS_CONFIG=/root/configuration.nix                            && \
 echo '{ fileSystems."/" = {};'              >  /root/configuration.nix && \
 echo '  boot.loader.grub.enable = false; }' >> /root/configuration.nix && \
 nix-env -i -A config.system.build.nixos-install \
            -A config.system.build.nixos-option  \
            -A config.system.build.nixos-generate-config \
         -f "<nixos>"
) >/dev/null 2>&1
EOF
)
  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"
}

function rackspace_generate_nixos_conf {
  log "Grabbing networking configuration..."
  # Now, substitute in values for the networking configuration.
  GATEWAY=$(do_ssh  $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "grep gateway /etc/network/interfaces | awk '{print \$2}' | head -1")
  NS1=$(do_ssh      $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "grep nameserver /etc/resolv.conf | awk '{print \$2}' | head -1")
  NS2=$(do_ssh      $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "grep nameserver /etc/resolv.conf | awk '{print \$2}' | tail -1")
  PUBIPV4=$(do_ssh  $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "grep address /etc/network/interfaces | awk '{print \$2}' | head -1")
  PRIVIPV4=$(do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "grep address /etc/network/interfaces | awk '{print \$2}' | tail -1")
  log "Network information acquired ($PUBIPV4/$PRIVIPV4; GW=$GATEWAY; NS=$NS1,$NS2)"

  log "Generating template/detecting hardware..."

  CMD=$(cat <<EOF
(. /root/.nix-profile/etc/profile.d/nix.sh                             && \
 export NIX_PATH=nixpkgs=/root/.nix-defexpr/channels/nixos:nixos=/root/.nix-defexpr/channels/nixos/nixos && \
 export NIXOS_CONFIG=/root/configuration.nix                           && \
 nixos-generate-config --root /mnt                                     && \
 rm -f /mnt/etc/nixos/configuration.nix
) >/dev/null 2>&1
EOF
)
  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"

  # Upload rackspace configuration
  TEMP_FILE=$(get_tmp_file nixos-configuration)
  echo "$RACKSPACE_NIXCFG" > $TEMP_FILE
  do_scp $RACKSPACE_SERVER_PASS $TEMP_FILE $RACKSPACE_HOST:/mnt/etc/nixos/rackspace-configuration.nix
  rm -f $TEMP_FILE

  # Upload source code to /mnt/etc/nixos
  do_scp_dir $RACKSPACE_SERVER_PASS $ATHENA_SRCDIR $RACKSPACE_HOST:/mnt/etc/nixos/athena

  # Symlink configuration.nix
  CMD=$(cat <<EOF
( cd /mnt/etc/nixos && \
  ln -s athena/src/machines/$RACKSPACE_SERVER_NAME.nix configuration.nix
) >/dev/null 2>&1
EOF
)
  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"

  # Perform substitutions
  CMD=$(cat <<EOF
(perl -pi -e "s/GATEWAY/$GATEWAY/" /mnt/etc/nixos/rackspace-configuration.nix    && \
 perl -pi -e "s/NAMESERVER1/$NS1/" /mnt/etc/nixos/rackspace-configuration.nix    && \
 perl -pi -e "s/NAMESERVER2/$NS2/" /mnt/etc/nixos/rackspace-configuration.nix    && \
 perl -pi -e "s/IPV4ADDR1/$PUBIPV4/" /mnt/etc/nixos/rackspace-configuration.nix  && \
 perl -pi -e "s/IPV4ADDR2/$PRIVIPV4/" /mnt/etc/nixos/rackspace-configuration.nix
) >/dev/null 2>&1
EOF
)

  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"
}

function rackspace_update_athena_hosts { # params: $1 = upload destination
  rackspace_login

  log "Updating hosts map..."
  UPLOAD_DEST=$1
  TEMP_FILE=$(get_tmp_file athena-hosts)
  RESULT=$(rackspace_list_servers_json)
  RESULT=$(echo "$RESULT" | jq -r '. | .name, .ip')

  echo '# Athena generated host mapping below! Do not modify!' > $TEMP_FILE
  (echo "$RESULT" | while read line1; do \
     read line2; \
     echo "$line2 $line1"; \
   done | sort) >> $TEMP_FILE;
  echo '# Athena generated host mapping above! Do not modify!' >> $TEMP_FILE
  do_scp $RACKSPACE_SERVER_PASS $TEMP_FILE $RACKSPACE_HOST:$UPLOAD_DEST
  rm -f $TEMP_FILE
}

function rackspace_install_nixos {
  log "Cloning nixpkgs..."
  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "git clone $NIXPKGS_GIT /mnt/root/nixpkgs >/dev/null 2>&1"
  log "Installing NixOS..."
  CMD=$(cat <<EOF
(. /root/.nix-profile/etc/profile.d/nix.sh && \
 export NIX_PATH=nixpkgs=/root/.nix-defexpr/channels/nixos:nixos=/root/.nix-defexpr/channels/nixos/nixos && \
 nixos-install
) >/dev/null 2>&1
EOF
)

  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "$CMD"
  # Note: rewrites the temporary GRUB installation path to the real
  # path (for when we reboot out of rescue mode). We do this after
  # because sometimes it seems `nixos-install` returns a non-0 error
  # code even though it pretty much succeeds.
  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "perl -pi -e 's#/dev/xvdb#/dev/xvda#' /mnt/etc/nixos/rackspace-configuration.nix"

  # Unmount and fsync disks
  do_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST "sync && umount /mnt"
}

## -----------------------------------------------------------------------------
## -- Main program

function rackspace_try_to_ssh { # params: $1 = pass; $2 = host
  DONE="0"
  TOTAL=0

  while [ ! "$DONE" = "1" ]; do
    do_ssh $1 $2 'true'
    if [ "$?" = "0" ]; then
      DONE="1"
    fi

    if [[ "$TOTAL" -ge "300" ]]; then
      log_error "Couldn't SSH in after 5 minutes? Exiting!";
      exit 1
    fi

    sleep 5
    TOTAL=$(($TOTAL + 5))
  done
}

function rackspace_assimilate { # params: $1 = server name

  athena_check_configuration_exists $1

  log "Creating and assimilating $1 (a Rackspace machine)"

  RACKSPACE_SERVER_NAME=$1
  rackspace_create_server $1

  RACKSPACE_HOST=root@$RACKSPACE_SERVER_IP

  log "Attempting SSH login..."
  rackspace_try_to_ssh $RACKSPACE_SERVER_PASS $RACKSPACE_HOST
  log "SSH login OK!"

  rackspace_setup_tools
  rackspace_partition_disk
  rackspace_format_disk
  rackspace_install_nixpkgs
  rackspace_update_nixpkgs
  rackspace_bootstrap_nixos_tools
  rackspace_generate_nixos_conf
  rackspace_update_athena_hosts "/mnt/etc/nixos/athena-hosts"
  rackspace_install_nixos

  log "Installation complete; now rebooting..."
  rackspace_unrescue_server
  log "Done. Try 'ssh $RACKSPACE_HOST' to log in."
}
