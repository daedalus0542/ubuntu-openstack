#!/bin/bash

MYSQL_ROOT_PWD="prettyplease"
NOVA_PWD="opensesame"
GLANCE_PWD="opensesame"

USERNAME="anuaimi"
PROJECT_NAME="project1"

INTERNAL_IP_RANGE="10.0.0.0/24"
INTERNAL_FIRST_IP="10.0.0.2"
FLOATING_IP_RANGE="10.153.107.72/29"

# assumptions
#  compute nodes have LVM named 'nova-volumes'


function initial_setup() {
	
	sudo apt-get update
	sudo apt-get install -y augeas-tools
}

function install_network() {
	sudo apt-get install -y bridge-utils
}

function install_ntp() {
	sudo apt-get install -y ntp

# 	# add following to /etc/ntp.conf
# cat <<EOF > augeas-ntp.conf
# ins server after /files/etc/ntp.conf/server[last()]
# set /files/etc/ntp.conf/server[last()] 127.127.0.1
# ins fudge after /files/etc/ntp.conf/server[last()]
# set /files/etc/ntp.conf/fudge "127.127.0.1 stratum 10"
# save
# EOF
# 	sudo augtool -s -f augeas-ntp.conf
# 	# fig bug in augeas lense for ntp.conf
# 	sudo sed -i 's/fudge stratum/fudge 127.127.0.1 stratum 10/g' /etc/ntp.conf
	
	# this is much simpler than above
	sudo sed -i 's/server ntp.ubuntu.com/server ntp.ubuntu.com\nserver 127.127.1.0\nfudge 127.127.1.0 stratum 10/g' /etc/ntp.conf

	# restart ntp with new settings
	sudo service ntp restart
}

function install_mysql() {

	# set password so apt-get does not prompt during install
	sudo apt-get -y install debconf-utils
	echo "mysql-server-5.5 mysql-server/root_password password ${MYSQL_ROOT_PWD}" > mysql.preseed
	echo "mysql-server-5.5 mysql-server/root_password_again password ${MYSQL_ROOT_PWD}" >> mysql.preseed
	echo "mysql-server-5.5 mysql-server/start_on_boot boolean true" >> mysql.preseed
	cat mysql.preseed | sudo debconf-set-selections

	sudo apt-get install -y python-mysqldb mysql-server

	# set mysql to be available to external requests
	sudo sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/my.cnf

	sudo service mysql restart
}

function install_rabbitmq() {
	sudo apt-get install -y rabbitmq-server
}

function create_nova_db() {
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE nova;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL ON nova.* TO novauser@localhost IDENTIFIED BY '${NOVA_PWD}';"
}

function install_nova() {
	sudo apt-get install -y nova-api nova-network nova-volume nova-objectstore nova-scheduler nova-compute euca2ools unzip
	sudo service libvirt-bin restart
}

function configure_nova() {

cat <<EOF > extra-nova.conf
# Nova config FlatDHCPManager
--sql_connection=mysql://novauser:${NOVA_PWD}@localhost/nova
--flat_injected=true
--network_manager=nova.network.manager.FlatDHCPManager
--fixed_range=${INTERNAL_IP_RANGE}
--floating_range=${FLOATING_IP_RANGE}
--flat_network_dhcp_start=${INTERNAL_FIRST_IP}
--flat_network_bridge=br100
--flat_interface=eth1
--public_interface=eth0
EOF
	sudo sh -c "sudo cat extra-nova.conf >> /etc/nova/nova.conf"

	# restart nova
	for i in nova-api nova-network nova-objectstore nova-scheduler nova-volume nova-compute; \
	do sudo stop $i; sleep 2; done

	for i in nova-api nova-network nova-objectstore nova-scheduler nova-volume nova-compute; \
	do sudo start $i; sleep 2; done

	# migrate db from sqlite to MySQL
	sudo nova-manage db sync

	sudo nova-manage network create --fixed_range_v4 ${INTERNAL_IP_RANGE} --label private --bridge_interface br100
	sudo nova-manage floating create --ip_range=${FLOATING_IP_RANGE}
}

function create_credentials() {
	cd ~
	mkdir nova
	cd nova
	sudo nova-manage user admin ${USERNAME}
	sudo nova-manage project create ${PROJECT_NAME} ${USERNAME}
	sudo nova-manage project zipfile ${PROJECT_NAME} ${USERNAME}
	unzip nova.zip
	source novarc
}

function create_glance_db() {
	sudo mysql -uroot -p${MYSQL_PWD} -e "CREATE DATABASE glance;"
	sudo mysql -uroot -p${MYSQL_PWD} -e "GRANT ALL ON glance.* TO glanceuser@localhost \
IDENTIFIED BY '${GLANCE_PWD}' ";
}

function install_glance() {
	sudo apt-get install -y glance

	# add to /etc/glance/glance-registry
#	sudo sed -i 's/^sql_connection/sql_connection = mysql://glanceuser:${GLANCE_PWD}@localhost/glance/g' /etc/glance/glance-registry

	sudo rm -fr /var/lib/glance/glance.sqlite

	sudo restart glance-registry
}

function get_ubuntu_images() {
	DISTRO=precise
	wget http://uec-images.ubuntu.com/${DISTRO}/current/${DISTRO}-server-cloudimg-amd64-disk1.img
#	DISTRO=quantal
#	wget http://uec-images.ubuntu.com/${DISTRO}/current/${DISTRO}-server-cloudimg-amd64-disk1.img

	# now how do I import?
}

#
# START
#

# 
#initial_setup

#install_network
#install_ntp
#install_mysql
#install_rabbitmq

#create_nova_db
#install_nova
#configure_nova

#create_credentials

create_glance_db
install_glance



