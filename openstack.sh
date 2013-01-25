#!/bin/bash


function initial_setup() {
	
	sudo apt-get update
	sudo apt-get install -y augeas-tools
}

# pass in interface (normally eth0 or p1p1)
function get_network_settings() {
	sudo apt-get install -y ipcalc

	inet_addr=$( ip addr show $1 | awk '/inet /{ print $2 }' )
	ip_address=$( ipcalc -bn $inet_addr | awk '/Address:/{ print $2 }' )
	ip_netmask=$( ipcalc -bn $inet_addr | awk '/Netmask:/{ print $2 }' )
	ip_dns_nameservers=$( awk '/nameserver/ { l = l $2 " " } END { print l }' /etc/resolv.conf )
	ip_gateway=$( route -n | awk '/^0.0.0.0/{ print $2 }')
	
	echo "Address = '$ip_address'  Netmask = '$ip_netmask'  Gateway = '$ip_gateway'  DNS = '$ip_dns_nameservers'"
}

function install_network() {

	get_network_settings ${IF_NAME}

#	sudo apt-get install -y vlan bridge-utils
	sudo apt-get install -y bridge-utils

	# backup interfaces file
	local __file="/etc/network/interfaces"
	sudo rm -f "$__file.bak"
	sudo cp "$__file" "$__file.bak"

sudo echo "
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto eth0
iface eth0 inet static
post-up ip link set eth0 promisc on
address ${ip_address}
netmask ${ip_netmask}
gateway ${ip_gateway}
dns-nameservers ${ip_dns_nameservers}

auto ${BRIDGE_INTERFACE}
iface br100 inet static
address ${BRIDGE_ADDRESS}
netmask ${FIXED_NETMASK}
bridge_ports none
bridge_stp off
bridge_fd 0
" >> interfaces
	sudo mv interfaces /etc/network/interfaces

	# setup bridge
	sudo brctl addbr ${BRIDGE_INTERFACE}

	/etc/init.d/networking restart

#	sudo sed -i 's/^#net.ipv4.ip_forward/net.ipv4.ip_forward/' /etc/sysctl.conf
#	sudo sysctl -p


}

function install_ntp() {
	sudo apt-get install -y ntp

 	# add following to /etc/ntp.conf
	sudo sed -i 's|server ntp.ubuntu.com|server ntp.ubuntu.com\nserver 127.127.1.0\nfudge 127.127.1.0 stratum 10|g' /etc/ntp.conf

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
	sudo sed -i 's|127.0.0.1|0.0.0.0|g' /etc/mysql/my.cnf

	sudo service mysql restart
	rm mysql.preseed
}

function install_rabbitmq() {
	sudo apt-get install -y rabbitmq-server
}

function keystone_create_db() {
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "DROP DATABASE IF EXISTS keystone;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE keystone;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${KEYSTONE_PWD}';"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${KEYSTONE_PWD}';"
}

function keystone_install() {
	sudo apt-get install -y keystone python-keystone python-keystoneclient
}

function keystone_configure() {

	# backup org config
	sudo cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.bak

	# remove old sqlite db
	sudo rm /var/lib/keystone/keystone.db
	
	# update config file
	MATCH='^# admin_token = ADMIN'
	REPLACEMENT="admin_token = ${ADMIN_TOKEN}"
	sudo sed -i "s|${MATCH}|${REPLACEMENT}|" /etc/keystone/keystone.conf

	MATCH='^connection =.*$'
	REPLACEMENT="connection = mysql://keystone:${KEYSTONE_PWD}@localhost/keystone"
	sudo sed -i "s|${MATCH}|${REPLACEMENT}|" /etc/keystone/keystone.conf

	MATCH='^# idle_timeout'
	REPLACEMENT="idle_timeout"
	sudo sed -i "s|${MATCH}|${REPLACEMENT}|" /etc/keystone/keystone.conf

	sudo service keystone restart
	sleep 2

	# create tables in keystone db
	sudo keystone-manage db_sync
	sudo service keystone restart
}

function keystone_setup_env() {

cat <<EOF > bash.rc
export SERVICE_TOKEN=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=openstack
export OS_AUTH_URL=http://localhost:5000/v2.0/
export SERVICE_ENDPOINT=http://localhost:35357/v2.0/
EOF

	source bashrc
}

function keystone_create_data() {
	# users
	keystone user-create --name admin --pass openstack --email ${EMAIL}
	keystone user-create --name nova --pass ${NOVA_PWD} --email ${EMAIL}
	keystone user-create --name glace --pass ${GLANCE_PWD} --email ${EMAIL}
	keystone user-create --name swift --pass ${SWIFT_PWD} --email ${EMAIL}
	keystone user-create --name cinder --pass ${CINDER_PWD} --email ${EMAIL}
	keystone user-create --name ovs_quantum --pass ${OVS_QUANTUM_PWD} --email ${EMAIL}

	# roles
	keystone role-create --name admin
	keystone role-create --name Member
	
	# tenants
	keystone tenant-create --name=service
	keystone tenant-create --name=admin

	# services
	keystone service-create --name nova --type compute --description "OpenStack Compute Service"
	keystone service-create --name volume --type volume --description "OpenStack Volume Service"
	keystone service-create --name glance --type image --description "OpenStack Image Service"
	keystone service-create --name swift --type object-store --description "OpenStack Storage Service"
	keystone service-create --name keystone --type identity --description "OpenStack Identity Service"
	keystone service-create --name ec2 --type ec2 --description "EC2 Service"
	keystone service-create --name cinder --type volume --description "Cinder Service"
	keystone service-create --name quantum --type network --description "OpenStack Networking service"
}


function nova_create_db() {
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "DROP DATABASE IF EXISTS nova;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE nova;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_PWD}';"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_PWD}';"
}

function nova_install() {
	sudo apt-get install -y nova-api nova-network nova-volume nova-objectstore nova-scheduler nova-compute euca2ools unzip
	sudo service libvirt-bin restart
}

function nova_configure() {

	MATCH="^sql_connection.*$"
	REPLACEMENT="sql_connection = mysql://nova:${NOVA_PWD}@localhost/nova"
	sudo sed -i "s|${MATCH}|${REPLACEMENT}|" /etc/nova/nova.conf

cat <<EOF > extra-nova.conf
sql_connection=mysql://nova:${NOVA_PWD}@localhost/nova
flat_injected=true
network_manager=nova.network.manager.FlatDHCPManager
fixed_range=${INTERNAL_IP_RANGE}
floating_range=${FLOATING_IP_RANGE}
flat_network_dhcp_start=${INTERNAL_FIRST_IP}
flat_network_bridge=br100
flat_interface=eth1
public_interface=${IF_NAME}
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


function glance_create_db() {
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "DROP DATABASE IF EXISTS glance;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE glance;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@localhost IDENTIFIED BY '${GLANCE_PWD}' ";
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '${GLANCE_PWD}' ";
}

function glance_install() {
	sudo apt-get install -y glance

	# add to /etc/glance/glance-registry
	MATCH="^sql_connection.*$"
	REPLACEMENT="sql_connection = mysql://glance:${GLANCE_PWD}@localhost/glance"
	sudo sed -i "s|${MATCH}|${REPLACEMENT}|" /etc/glance/glance-registry.conf

	sudo rm -fr /var/lib/glance/glance.sqlite

	sudo restart glance-registry
}

function glance_get_ubuntu_images() {
	DISTRO=precise
	wget http://uec-images.ubuntu.com/${DISTRO}/current/${DISTRO}-server-cloudimg-amd64-disk1.img
#	DISTRO=quantal
#	wget http://uec-images.ubuntu.com/${DISTRO}/current/${DISTRO}-server-cloudimg-amd64-disk1.img

	# now how do I import?
}

function create_dash_db() {
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "DROP DATABASE IF EXISTS dash;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE dash;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON dash.* TO 'dash'@localhost IDENTIFIED BY '${DASH_PWD}' ";
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON dash.* TO 'dash'@'%' IDENTIFIED BY '${DASH_PWD}' ";
}

function create_cinder_db() {
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "DROP DATABASE IF EXISTS cinder;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE cinder;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@localhost IDENTIFIED BY '${CINDER_PWD}' ";
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '${CINDER_PWD}' ";
}

function create_ovs_quantum_db() {
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "DROP DATABASE IF EXISTS ovs_quantum;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE ovs_quantum;"
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON ovs_quantum.* TO 'ovs_quantum'@localhost IDENTIFIED BY '${OVS_QUANTUM_PWD}' ";
	sudo mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON ovs_quantum.* TO 'ovs_quantum'@'%' IDENTIFIED BY '${OVS_QUANTUM_PWD}' ";
}

#
# START
#

# load config
source ./stackrc
 
initial_setup

# setup network
install_network
install_ntp

# install database & queue
install_mysql
install_rabbitmq
#exit

# install identify module
keystone_create_db
keystone_install
keystone_configure
keystone_setup_env
keystone_create_data
#exit

# install compute module
nova_create__db
nova_install
nova_configure
#exit

# install dashboard
create_dash_db

glance_create_db
glance_install
glance_configure
glance_get_ubuntu_images
#exit

create_cinder_db
create_ovs_quantum_db




