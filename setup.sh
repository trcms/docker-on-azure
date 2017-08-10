#!/bin/bash

export DOCKER_FOR_IAAS_VERSION="17.06.0-ce-azure1"
export DOCKER_FOR_UBUNTU_VERSION="17.06.0~ce-0~ubuntu"

sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common vim
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce=$DOCKER_FOR_UBUNTU_VERSION

sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "log-driver": "syslog",
  "log-opts": {
    "syslog-address": "udp://localhost:514",
    "tag": "{{.Name}}/{{.ID}}"
  },
  "storage-driver": "overlay2",
  "userns-remap": "default"
}
EOF

sudo usermod -aG docker $ADMIN_USER
sudo systemctl enable docker
sudo systemctl restart docker

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
           --userns=host \
           --privileged \
           quay.io/ctrack/init-azure:$DOCKER_FOR_IAAS_VERSION