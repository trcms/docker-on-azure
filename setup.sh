#!/bin/bash

export DOCKER_FOR_IAAS_VERSION="17.06.0-ce-azure1"
export DOCKER_FOR_UBUNTU_VERSION="17.06.0~ce-0~ubuntu"

# ensure system is up to date, add prerequisite dependencies
sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common vim

#set up docker repo
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

#set up azure cli repo
sudo apt-key adv --keyserver packages.microsoft.com --recv-keys 417A0893
sudo add-apt-repository "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ wheezy main"

#refresh package list and install 
sudo apt-get update
sudo apt-get install -y docker-ce=$DOCKER_FOR_UBUNTU_VERSION azure-cli

#update docker config
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "storage-driver": "overlay2"
}
EOF

#enable ssh user to run docker commands without sudo
sudo usermod -aG docker $ADMIN_USER
#start docker on boot
sudo systemctl enable docker
#bounce docker for config changes
sudo systemctl restart docker

#login to azure with service principal
az login --service-principal -u $APP_ID -p $APP_SECRET --tenant $TENANT_ID
#create share
az storage share create --name $SWARM_VOLUME_SHARE --account-name $SWARM_STORAGE_ACCOUNT
#get storage account access key 
SA_KEY=`az storage account keys list --resource-group $GROUP_NAME --account-name $SWARM_STORAGE_ACCOUNT | python -c "import sys, json; print json.load(sys.stdin)[0]['value']"`
#get full endpoint for storage account (not sure if this domain differs for government or not)
SA_ENDPOINT=`az storage account show --resource-group $GROUP_NAME --name $SWARM_STORAGE_ACCOUNT | python -c "import sys, json; print json.load(sys.stdin)['primaryEndpoints']['file'].replace('/', '').split(':')[1]"`

#create local mountpoint for volumes (/mnt is already used by azure)
sudo mkdir -p /volumes
sudo chmod 777 /volumes

#update fstab for storage account
echo "//$SA_ENDPOINT/$SWARM_VOLUME_SHARE /volumes cifs vers=3.0,username=$SWARM_STORAGE_ACCOUNT,password=$SA_KEY,dir_mode=0777,file_mode=0777,sec=ntlmssp 0 0" | sudo tee -a /etc/fstab
sudo mount /volumes

#kick off a modified version of the swarm init container
sudo -E docker run --label com.docker.editions.system \
           --log-driver=json-file \
           --restart=no \
           -i \
           -e SUB_ID \
           -e ROLE \
           -e REGION \
           -e TENANT_ID \
           -e APP_ID \
           -e APP_SECRET \
           -e ACCOUNT_ID \
           -e GROUP_NAME \
           -e PRIVATE_IP \
           -e DOCKER_FOR_IAAS_VERSION \
           -e SWARM_INFO_STORAGE_ACCOUNT \
           -e SWARM_LOGS_STORAGE_ACCOUNT \
           -e AZURE_HOSTNAME \
           -v /var/run/docker.sock:/var/run/docker.sock \
           -v /var/lib/docker:/var/lib/docker \
           -v /var/log:/var/log \
           quay.io/ctrack/init-azure:$DOCKER_FOR_IAAS_VERSION