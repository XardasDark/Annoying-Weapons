#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

##
#	Helper functions
##

usage(){
	cat <<EOF
revertToSetup.sh 1.0.0
Revert a Whizcart back to the Hardware Check and Setup phase
This script needs to be run as root

Usage:
	-h --help		show this help and exit
	-d --debug		print debuging output
	-n --networkOnly	only restore the network to the Setup wifi without installing the Setup package
	-r --reload		reload network settings and restart all services after installation. Reboot should not be required
	-q --quiet		don't show any output
EOF
}

echoDebug(){
	if [ $DEBUG = "true" ]
	then
		echo ""
		echo $1
		echo ""
	fi
}

restoreNetwork(){
	if [ -f /etc/netplan/01-netcfg.yaml.preWhizcartNetwork ]
	then
		echoDebug "found prewhizcart netplan config, enabeling it agian"
		mv /etc/netplan/01-netcfg.yaml.preWhizcartNetwork /etc/netplan/01-netcfg.yaml
	else
		echoDebug "did not find prewhizcart netplan, using default from script"
		cat <<EOF > /etc/netplan/01-netcfg.yaml
# This file describes the network interfaces available on your system
# For more information, see netplan(5).
network:
  version: 2
  renderer: networkd
  wifis:
    wlp6s0:
      access-points:
        nossid: {password: nopassword} # it wont be used, wpa_supplicant will be used instead. Kept it to start wpa_supplicant
      dhcp4: yes
      dhcp6: false
      optional: true
      nameservers:
        addresses: [8.8.8.8]
  ethernets:
    enp1s0:
      dhcp4: true
      dhcp6: false
      optional: true
    enp5s0:
      dhcp4: false
      dhcp6: false
      addresses: [192.168.0.1/24]
      optional: true
EOF
	fi

	if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]
	then
		echoDebug "did not find wpa_supplicant, using default from script"
		cat <<EOF > /etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=/run/wpa_supplicant # needed for netplan
ctrl_interface_group=sudo
country=DE
update_config=1

network={
	ssid="setup"
	psk="k4itR8cS98"
}
EOF
	fi

	echoDebug "restoring netplan-wpa@.service from script"
	cat <<EOF > /lib/systemd/system/netplan-wpa@.service
[Unit]
Description=WPA supplicant for netplan %I
Requires=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device
Before=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/sbin/wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant.conf -i%I
EOF

	if [ $RELOAD = "true" ]
	then
		echoDebug "applying netplan"
		netplan apply
	fi
}

##
#	Parse Arguments
##

PARAMS=""
RELOAD="false"
REBOOT="false"
DEBUG="false"
NETWORKONLY="false"

while [ $# -gt 0 ]
do
  case "$1" in

    -r|--reload)
      RELOAD="true"
      echo "reloadflag given"
      shift
      ;;

  --reboot)
      REBOOT="true"
      echo "reboot flag given"
      shift
      ;;

	-n|--networkOnly)
	  NETWORKONLY="false"
	  echo "restoring network only"
	  shift
	  ;;

	-d|--debug)
	  DEBUG="true"
	  echo "enable debug"
	  shift
	  ;;

	-h|--help)
	  usage
	  exit 0
	  ;;

	-q|--quiet)
	  exec > /dev/null
	  shift
	  ;;


    --) # end argument parsing
      shift
      break
      ;;
    -*|--*=) # unsupported flags
      echo "Error: Unsupported flag $1" >&2
      exit 2
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done

# set positional arguments in their proper place
eval set -- "$PARAMS"


##
#	Check if we are root
##

if [ $(id -u) != 0 ]
then
    echo not run as root, please use sudo
    exit 1
fi


##
#	Done, start actual work
##

if [ $NETWORKONLY = "true" ]
then
	restoreNetwork
	exit 0
fi

if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config
then
    echoDebug "reenabeling password authentification"
    sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
    systemctl restart sshd
fi

echoDebug "stop all running docker containers"
docker stop $(docker ps -aq)

echoDebug "pruning docker"
docker system prune -f

echoDebug "purging whizcart packages"
apt-get purge -y whizcart-*

# Delete deployment-service config-things
rm -rf /opt/whizcart/deployment

rm -rf /etc/apt/sources.list.d/whizcart.packages.list /etc/apt/sources.list.d/whizcart.docker.packages.list

if [ ! -f /etc/apt/sources.list.d/whizcart-setup.list ]
then
	echoDebug "setup package list not existant, using default from script"
	cat <<EOF > /etc/apt/sources.list.d/whizcart-setup.list
deb [arch=amd64 trusted=yes] http://172.30.20.60:5001/ubuntu/ wc4 stable
deb [arch=amd64 trusted=yes] http://172.30.20.100:5001/ubuntu/ wc4 stable
deb [trusted=yes arch=amd64] https://download.docker.com/linux/ubuntu bionic stable
EOF
fi


echoDebug "updating apt indices"
apt-get update
echoDebug "installing whizcart-initialsetup"
apt-get install -y -o Dpkg::Options::="--force-confnew" whizcart-initialsetup

if [ $RELOAD = "true" ]
then
	echoDebug "reloading Services"
	systemctl daemon-reload
	echoDebug "applying netplan"
	netplan apply
	echoDebug "restarting services"
	systemctl stop whizcart-cart-deployment.service
	systemctl restart x11.service
	systemctl restart nginx.service
	systemctl restart whizcart-hardware-check.service
	systemctl restart electron.service
fi

echoDebug "Done!"

if [ $REBOOT = "true" ]
then
	echoDebug "rebooting now"
	reboot
fi
