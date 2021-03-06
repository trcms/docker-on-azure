#!/bin/bash

export DOCKER_FOR_UBUNTU_VERSION="17.06.2~ce-0~ubuntu"

# ensure system is up to date, add prerequisite dependencies
sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common ntp vim unzip

#set up docker repo
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

#refresh package list and install 
sudo apt-get update
sudo apt-get install -y docker-ce=$DOCKER_FOR_UBUNTU_VERSION

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

#set timezone
sudo timedatectl set-timezone $AZURE_TIMEZONE

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
echo "//$STORAGE_ACCOUNT_NAME.$STORAGE_ACCOUNT_DNS/$SWARM_VOLUME_SHARE $REMOTE_VOLUME_DIR cifs vers=3.0,username=$STORAGE_ACCOUNT_NAME,password=$SA_KEY,dir_mode=0777,file_mode=0777,sec=ntlmssp,nobrl,noperm 0 0" | sudo tee -a /etc/fstab
sudo mount $REMOTE_VOLUME_DIR

#convert delimeted string to bash array, loop through
REMOTE_MOUNTS=$(echo $SWARM_VOLUME_REMOTE_MOUNTS | tr ' ' "\n")
for REMOTE_MOUNT in ${REMOTE_MOUNTS[@]}; do
  sudo mkdir -p $REMOTE_VOLUME_DIR/$REMOTE_MOUNT
done

#now that we have access to share storage, create folder for swarm join tokens
sudo mkdir -p $REMOTE_VOLUME_DIR/.swarminfo

#initialize some variables
MANAGER_JOIN_TOKEN=$REMOTE_VOLUME_DIR/.swarminfo/manager-join-token
WORKER_JOIN_TOKEN=$REMOTE_VOLUME_DIR/.swarminfo/worker-join-token

JOIN_TOKEN=""
LOOP_COUNTER=0

#if we're on a manager node:
if [[ $AZURE_HOSTNAME == swarm-manager* ]]; then
  #if we're on manager0 and we don't have both token files:
  if [[ $AZURE_HOSTNAME == *0 && !(-f $MANAGER_JOIN_TOKEN && -f $WORKER_JOIN_TOKEN) ]]; then
    echo "running from first manager node and no tokens exist; initiating swarm"
    #clean up old files if we're in a bad state
    rm -f $MANAGER_JOIN_TOKEN
    rm -f $WORKER_JOIN_TOKEN
    #initialize the swarm and write out the join tokens to files on the share
    docker swarm init
    docker swarm join-token manager | grep "docker swarm join" | xargs > $MANAGER_JOIN_TOKEN
    docker swarm join-token worker | grep "docker swarm join" | xargs > $WORKER_JOIN_TOKEN
    #bail out after starting the swarm
    exit 0
  #otherwise we're either a different manager node, or manager0 after the swarm has been created
  else
    JOIN_TOKEN=$MANAGER_JOIN_TOKEN
  fi
#otherwise we're on a worker node
else
  JOIN_TOKEN=$WORKER_JOIN_TOKEN
fi

#wait around for 5 minutes for the join token files to be created
echo "waiting for join token..."
until [[ -f $JOIN_TOKEN || $LOOP_COUNTER -ge 60 ]]; do
  LOOP_COUNTER=$((LOOP_COUNTER+1))
  echo "    iteration $LOOP_COUNTER, sleeping for 5 seconds..."
  sleep 5
done

#error out if we hit the timeout and still no file
if [[ ! -f $JOIN_TOKEN ]]; then
  echo "no join token after 5 minutes, timing out"
  exit 1
fi

#run the join command if the file exists
echo "found join token info; joining swarm"
sh $JOIN_TOKEN
