#!/bin/bash

# Variables
CLUSTERNAME="mycluster1"
LOCATION="uksouth"

PUBSSHKEY=""
IMAGEPATH=""

NODECOUNT=3

# Create Resource Group
az group create --name $CLUSTERNAME --location $LOCATION

# Deploy Network
az group deployment create --name $CLUSTERNAME-network --resource-group $CLUSTERNAME --template-file network.json --parameters clustername="$CLUSTERNAME"

# Deploy Head
az group deployment create --name $CLUSTERNAME-head --resource-group $CLUSTERNAME --template-file head1.json --parameters ssh-key="$PUBSSHKEY" image-path="$IMAGEPATH" clustername="$CLUSTERNAME"

# Deploy Compute
for i in $(eval echo {01..0$NODECOUNT}) ; do
    nodename="node$i"
    az group deployment create --name $CLUSTERNAME-$nodename --resource-group $CLUSTERNAME --template-file node.json --parameters name="$nodename" ip="10.110.1.1$i" clustername="$CLUSTERNAME" image-path="$IMAGEPATH" ssh-key="$PUBSSHKEY"
done

# Basic Configuration
HEADIP=$(az network public-ip show -g $CLUSTERNAME -n head1pubIP --query "{address: ipAddress}" --output yaml |awk '{print $2}')
SSHARGS="-q -o StrictHostKeyChecking=no"

## Head1 

### Allow root SSH
ssh $SSHARGS flight@$HEADIP "sudo sed -i 's/.*ssh-rsa/ssh-rsa/g' /root/.ssh/authorized_keys"

### Set internal network firewall
ssh $SSHARGS root@$HEADIP "firewall-cmd --add-interface eth1 --zone trusted --permanent"

### Enable IP Forwarding
ssh $SSHARGS root@$HEADIP "firewall-cmd --add-rich-rule='rule family="ipv4" source address="10.110.0.0/16" masquerade' --zone public --permanent"
ssh $SSHARGS root@$HEADIP "firewall-cmd --set-target=ACCEPT --zone public --permanent"
ssh $SSHARGS root@$HEADIP "firewall-cmd --add-interface eth0 --zone public --permanent"
ssh $SSHARGS root@$HEADIP "firewall-cmd --reload" 
ssh $SSHARGS root@$HEADIP "echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.conf"
ssh $SSHARGS root@$HEADIP "echo 1 > /proc/sys/net/ipv4/ip_forward"

### Format & Mount Export Disk
DISK=/dev/disk/azure/scsi1/lun0
PART=$DISK-part1
ssh $SSHARGS root@$HEADIP "parted $DISK --script mklabel gpt"
ssh $SSHARGS root@$HEADIP "parted -a optimal ${DISK} --script mkpart primary ext4 0% 100%"
ssh $SSHARGS root@$HEADIP "mkfs.xfs ${PART} -L export"
ssh $SSHARGS root@$HEADIP "echo 'LABEL=export	/export/	xfs	defaults,nofail	0 2' >> /etc/fstab"
ssh $SSHARGS root@$HEADIP "mkdir /export"
ssh $SSHARGS root@$HEADIP "mount /export"

### Hostfile setup 
ssh $SSHARGS root@$HEADIP "echo '10.110.1.200    head1' >> /etc/hosts"
for i in $(eval echo {01..0$NODECOUNT}) ; do
    ssh $SSHARGS root@$HEADIP "echo '10.110.1.1$i    node$i' >> /etc/hosts"
done

## Nodes
for i in $(eval echo {01..0$NODECOUNT}) ; do
    nodeip=10.110.1.1$i

    ### Allow root SSH
    ssh $SSHARGS -J root@$HEADIP flight@$nodeip "sudo sed -i 's/.*ssh-rsa/ssh-rsa/g' /root/.ssh/authorized_keys"

    ### Disable firewall
    ssh $SSHARGS -J root@$HEADIP root@$nodeip "systemctl disable firewalld ; systemctl stop firewalld"

    ### Hostfile Setup
    ssh $SSHARGS -J root@$HEADIP root@$nodeip "echo '10.110.1.200    head1' >> /etc/hosts"
    for i in $(eval echo {01..0$NODECOUNT}) ; do
        ssh $SSHARGS -J root@$HEADIP root@$nodeip "echo '10.110.1.1$i    node$i' >> /etc/hosts"
    done
done

