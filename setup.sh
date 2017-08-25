#!/bin/bash

export DOCKER_FOR_IAAS_VERSION="17.06.1-ce-azure1"
export DOCKER_FOR_UBUNTU_VERSION="17.06.1~ce-0~ubuntu"

# ensure system is up to date, add prerequisite dependencies
sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common vim unzip

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
  "storage-driver" : "overlay2",
  "metrics-addr" : "0.0.0.0:9323",
  "experimental" : true,
  "log-opts" : {
    "max-size" : "5m",
    "max-file" : "3"
  }
}
EOF

#enable ssh user to run docker commands without sudo
sudo usermod -aG docker $ADMIN_USER
#start docker on boot
sudo systemctl enable docker
#bounce docker for config changes
sudo systemctl restart docker

#set max map kernel option appropriately for elasticsearch
sudo sysctl -w vm.max_map_count=262144
#ensure value gets set on restart
echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/60-max-maps.conf > /dev/null

#if we're deploying to government, set the cloud first
[ "$GOVERNMENT_CLOUD" == "True" ] && az cloud set --name AzureUSGovernment
#login to azure with service principal
az login --service-principal -u $APP_ID -p $APP_SECRET --tenant $TENANT_ID
#get storage account access key 
SA_KEY=`az storage account keys list --resource-group $GROUP_NAME --account-name $SWARM_STORAGE_ACCOUNT | python -c "import sys, json; print json.load(sys.stdin)[0]['value']"`
#get full endpoint for storage account (not sure if this domain differs for government or not)
SA_ENDPOINT=`az storage account show --resource-group $GROUP_NAME --name $SWARM_STORAGE_ACCOUNT | python -c "import sys, json; print json.load(sys.stdin)['primaryEndpoints']['file'].replace('/', '').split(':')[1]"`

#create share
az storage share create --name $SWARM_VOLUME_SHARE --account-name $SWARM_STORAGE_ACCOUNT

#create directory for local volumes (grafana and prometheus have issues with writing to cifs shares)
LOCAL_VOLUME_DIR=/volumes/local
sudo mkdir -p $LOCAL_VOLUME_DIR
#convert delimeted string to bash array, loop through
LOCAL_MOUNTS=$(echo $SWARM_VOLUME_LOCAL_MOUNTS | tr ' ' "\n")
for LOCAL_MOUNT in ${LOCAL_MOUNTS[@]}; do
  sudo mkdir -p $LOCAL_VOLUME_DIR/$LOCAL_MOUNT
  sudo chmod 777 $LOCAL_VOLUME_DIR/$LOCAL_MOUNT
done

#create directory for remote volumes
REMOTE_VOLUME_DIR=/volumes/remote
sudo mkdir -p $REMOTE_VOLUME_DIR

#add share to fstab
echo "//$SA_ENDPOINT/$SWARM_VOLUME_SHARE $REMOTE_VOLUME_DIR cifs vers=3.0,username=$SWARM_STORAGE_ACCOUNT,password=$SA_KEY,dir_mode=0777,file_mode=0777,sec=ntlmssp,nobrl,noperm 0 0" | sudo tee -a /etc/fstab
sudo mount $REMOTE_VOLUME_DIR

#convert delimeted string to bash array, loop through
REMOTE_MOUNTS=$(echo $SWARM_VOLUME_REMOTE_MOUNTS | tr ' ' "\n")
for REMOTE_MOUNT in ${REMOTE_MOUNTS[@]}; do
  sudo mkdir -p $REMOTE_VOLUME_DIR/$REMOTE_MOUNT
done

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
