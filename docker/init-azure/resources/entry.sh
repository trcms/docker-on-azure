#!/bin/bash
echo "#================"
echo "Start Swarm setup"
echo "PATH=$PATH"
echo "ROLE=$ROLE"
echo "PRIVATE_IP=$PRIVATE_IP"
echo "DOCKER_FOR_IAAS_VERSION=$DOCKER_FOR_IAAS_VERSION"
echo "ACCOUNT_ID=$ACCOUNT_ID"
echo "REGION=$REGION"
echo "AZURE_HOSTNAME=$HOSTNAME"
echo "CHANNEL=$CHANNEL"
echo "EDITION_ADDON=$EDITION_ADDON"
echo "RESOURCE_MANAGER_ENDPOINT=$RESOURCE_MANAGER_ENDPOINT"
echo "STORAGE_ENDPOINT=$STORAGE_ENDPOINT"
echo "ACTIVE_DIRECTORY_ENDPOINT=$ACTIVE_DIRECTORY_ENDPOINT"
echo "SERVICE_MANAGEMENT_ENDPOINT=$SERVICE_MANAGEMENT_ENDPOINT"
echo "#================"

export SWARM_INFO_STORAGE_ACCOUNT=$SWARM_STORAGE_ACCOUNT

if [ -z $CHANNEL ]; then
    CHANNEL=$(aztags.py channel)
fi
# these need to be kept in sync with the template file
# we cannot reference variables to pass these in through customData
# since changes in customData will block upgrades!
export VMSS_MGR="swarm-manager-vmss"
export VMSS_WRK="swarm-worker-vmss"

get_swarm_id()
{
    if [ "$ROLE" == "MANAGER" ] ; then
        export SWARM_ID=$(docker info | grep ClusterID | cut -f2 -d: | sed -e 's/^[ \t]*//')
    else
        # not available in docker info. might be available in future release.
        export SWARM_ID='n/a'
    fi
    echo "SWARM_ID: $SWARM_ID"
}

get_node_id()
{
    export NODE_ID=$(docker info | grep NodeID | cut -f2 -d: | sed -e 's/^[ \t]*//')
    echo "NODE: $NODE_ID"
}

get_leader_ip()
{
    echo "Get Leader IP from Azure Table"
    export LEADER_IP=$(azureleader.py get-ip)
}

get_manager_token()
{
    if [ -n "$LEADER_IP" ]; then
        export MANAGER_TOKEN=$(curl http://$LEADER_IP:9024/token/manager/)
        echo "MANAGER_TOKEN=$MANAGER_TOKEN"
    else
        echo "MANAGER_TOKEN can't be found yet. LEADER_IP isn't set yet."
    fi
}

get_worker_token()
{
    if [ -n "$LEADER_IP" ]; then
        export WORKER_TOKEN=$(curl http://$LEADER_IP:9024/token/worker/)
        echo "WORKER_TOKEN=$WORKER_TOKEN"
    else
        echo "WORKER_TOKEN can't be found yet. LEADER_IP isn't set yet."
    fi
}

confirm_leader_ready()
{
    n=0
    until [ $n -ge 5 ]
    do
        get_leader_ip
        echo "LEADER_IP=$LEADER_IP"
        if [ "$ROLE" == "MANAGER" ] ; then
            get_manager_token
            ROLE_TOKEN=$MANAGER_TOKEN
        else
            get_worker_token
            ROLE_TOKEN=$WORKER_TOKEN
        fi
        # if Leader IP or Role token is empty or Role_token is null, not ready yet.
        # token would be null for a short time between swarm init, and the time the
        # token is added to azure table
        if [ -z "$LEADER_IP" ] || [ -z "$ROLE_TOKEN" ] || [ "$ROLE_TOKEN" == "null" ]; then
            echo "Leader Not ready yet, sleep for 60 seconds."
            sleep 60
            n=$[$n+1]
        else
            echo "Leader is ready."
            break
        fi
    done
}

join_as_manager()
{
    echo "   Joining as Swarm Manager"
    if [ -z "$LEADER_IP" ] || [ -z "$MANAGER_TOKEN" ] || [ "$MANAGER_TOKEN" == "null" ]; then
        confirm_leader_ready
    fi
    echo "   LEADER_IP=$LEADER_IP"
    echo "   MANAGER_TOKEN=$MANAGER_TOKEN"
    # sleep for 30 seconds to make sure the leader has enough time to setup before
    # we try and join.

    sleep 30
    # we are not leader, so join as manager.
    n=0
    until [ $n -ge 5 ]
    do
        docker swarm join --token $MANAGER_TOKEN --listen-addr $PRIVATE_IP:2377 --advertise-addr $PRIVATE_IP:2377 $LEADER_IP:2377

        get_swarm_id
        get_node_id

        # check if we have a NODE_ID, if so, we were able to join, if not, it failed.
        if [ -z "$NODE_ID" ]; then
            echo "Can't connect to leader, sleep and try again"
            sleep 60
            n=$[$n+1]

            # query azure table again, incase the manager changed
            get_leader_ip
            get_manager_token
        else
            echo "Connected to leader, NODE_ID=$NODE_ID , SWARM_ID=$SWARM_ID"
            break
        fi
    done
    echo "   Successfully joined as a Swarm Manager"
}

setup_manager()
{
    echo "Setup Swarm Manager"
    echo "   PRIVATE_IP=$PRIVATE_IP"
    echo "   LEADER_IP=$LEADER_IP"

    if [ -z "$LEADER_IP" ]; then
        echo "Leader IP not set yet, lets try and set it."
        # try to create the azure table that will store tokens, if it succeeds then it is the first
        # and it is the leader. If it fails, then it isn't the leader .. so treat the record
        # that is there, as the leader, and join that swarm.
        azureleader.py create-table
        RESULT=$?
        echo "   Result of attempt to create swarminfo table: $RESULT"

        if [ $RESULT -eq 0 ]; then
            echo "   Swarm leader init"
            # we are the leader, so init the cluster
            docker swarm init --listen-addr $PRIVATE_IP:2377 --advertise-addr $PRIVATE_IP:2377
            # we can now get the swarm id and node id.
            get_swarm_id
            get_node_id

            # update azure table with the ip
            azureleader.py insert-ip $PRIVATE_IP

            echo "   Leader init complete"
        else
            echo " Error is normal, it is because we already have a swarm leader, lets setup a regular manager instead."
            join_as_manager
        fi
    elif [ "$PRIVATE_IP" == "$LEADER_IP" ]; then
        echo "   PRIVATE_IP == LEADER_IP, we are already the leader, maybe it was a reboot?"
        SWARM_STATE=$(docker info | grep Swarm | cut -f2 -d: | sed -e 's/^[ \t]*//')
        # should be active, pending or inactive
        echo "   Swarm State = $SWARM_STATE"
        # check if swarm is good?
    else
        echo "   join as a swarm Manager"
        join_as_manager
    fi

}

setup_worker()
{
    echo " Setup Worker"
    if [ -z "$LEADER_IP" ] || [ -z "$WORKER_TOKEN" ] || [ "$WORKER_TOKEN" == "null" ]; then
        confirm_leader_ready
    fi

    echo "   LEADER_IP=$LEADER_IP"
    # try an connect to the swarm manager.
    n=0
    until [ $n -ge 5 ]
    do
        docker swarm join --token $WORKER_TOKEN $LEADER_IP:2377
        get_swarm_id
        get_node_id

        # check if we have a NODE_ID, if so, we were able to join, if not, it failed.
        if [ -z "$NODE_ID" ]; then
            echo "Can't connect to leader, sleep and try again"
            sleep 60
            n=$[$n+1]

            # query azure table again, incase the leader changed
            get_leader_ip
            get_worker_token
        else
            echo "Connected to leader, NODE_ID=$NODE_ID , SWARM_ID=$SWARM_ID"
            break
        fi
    done
}


run_system_containers()
{
    if [ "$ROLE" = "MANAGER" ]; then
        echo "kick off meta container"
        docker run \
            --label com.docker.editions.system \
            --log-driver=json-file \
            --name=meta-azure \
            --restart=always \
            -d \
            -p $PRIVATE_IP:9024:8080 \
            -e APP_ID \
            -e APP_SECRET \
            -e ACCOUNT_ID \
            -e TENANT_ID \
            -e GROUP_NAME \
            -e RESOURCE_MANAGER_ENDPOINT \
            -e VMSS_MGR="$VMSS_MGR" \
            -e VMSS_WRK="$VMSS_WRK" \
            -v /var/run/docker.sock:/var/run/docker.sock \
            --privileged \
            docker4x/meta-azure:$DOCKER_FOR_IAAS_VERSION metaserver -iaas_provider=azure
    fi
}

# invoke system containers
run_system_containers

# try to obtain leader ip
get_leader_ip
# if it is a manager, setup as manager, if not, setup as worker node.
if [ "$ROLE" == "MANAGER" ] ; then
    echo " It's a Manager, run setup"
    get_manager_token
    setup_manager
else
    echo " It's a worker Node, run setup"
    get_worker_token
    setup_worker
fi

# show the results.
echo "#================ docker info    ==="
docker info
if [ "$ROLE" == "MANAGER" ] ; then
    echo "#================ docker node ls ==="
    docker node ls
fi
echo "#==================================="
echo "Complete Swarm setup"
