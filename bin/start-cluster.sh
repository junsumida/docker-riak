#! /usr/bin/env bash

set -e

if env | grep -q "DOCKER_RIAK_DEBUG"; then
  set -x
fi

CLEAN_DOCKER_HOST="localhost"

DOCKER_RIAK_CLUSTER_SIZE=${DOCKER_RIAK_CLUSTER_SIZE:-5}
DOCKER_RIAK_BACKEND=${DOCKER_RIAK_BACKEND:-bitcask}

if docker ps -a | grep "hectcastro/riak" >/dev/null; then
  echo ""
  echo "It looks like you already have some Riak containers running."
  echo "Please take them down before attempting to bring up another"
  echo "cluster with the following command:"
  echo ""
  echo "  make stop-cluster"
  echo ""

  exit 1
fi

echo
echo "Bringing up cluster nodes:"
echo

# The default allows Docker to forward arbitrary ports on the VM for the Riak
# containers. Ports used by default are usually in the 49xx range.

publish_http_port="8098"
publish_pb_port="8087"

# If DOCKER_RIAK_BASE_HTTP_PORT is set, port number
# $DOCKER_RIAK_BASE_HTTP_PORT + $index gets forwarded to 8098 and
# $DOCKER_RIAK_BASE_HTTP_PORT + $index + $DOCKER_RIAK_PROTO_BUF_PORT_OFFSET
# gets forwarded to 8087. DOCKER_RIAK_PROTO_BUF_PORT_OFFSET is optional and
# defaults to 100.

DOCKER_RIAK_PROTO_BUF_PORT_OFFSET=${DOCKER_RIAK_PROTO_BUF_PORT_OFFSET:-100}

for index in $(seq "1" "${DOCKER_RIAK_CLUSTER_SIZE}");
do
  index=$(printf "%.2d" "$index")
  if [[ ! -z $DOCKER_RIAK_BASE_HTTP_PORT ]] ; then
    final_http_port=$((DOCKER_RIAK_BASE_HTTP_PORT + index))
    final_pb_port=$((DOCKER_RIAK_BASE_HTTP_PORT + index + DOCKER_RIAK_PROTO_BUF_PORT_OFFSET))
    publish_http_port="${final_http_port}:8098"
    publish_pb_port="${final_pb_port}:8087"
  fi

  if [ "${index}" -gt "1" ] ; then
    docker run -e "DOCKER_RIAK_CLUSTER_SIZE=${DOCKER_RIAK_CLUSTER_SIZE}" \
               -e "DOCKER_RIAK_AUTOMATIC_CLUSTERING=${DOCKER_RIAK_AUTOMATIC_CLUSTERING}" \
               -e "DOCKER_RIAK_BACKEND=${DOCKER_RIAK_BACKEND}" \
               -p $publish_http_port \
               -p $publish_pb_port \
               --link "riak01:seed" \
               --name "riak${index}" \
               -d junsumida/docker-riak > /dev/null 2>&1
  else
    docker run -e "DOCKER_RIAK_CLUSTER_SIZE=${DOCKER_RIAK_CLUSTER_SIZE}" \
               -e "DOCKER_RIAK_AUTOMATIC_CLUSTERING=${DOCKER_RIAK_AUTOMATIC_CLUSTERING}" \
               -e "DOCKER_RIAK_BACKEND=${DOCKER_RIAK_BACKEND}" \
               -p $publish_http_port \
               -p $publish_pb_port \
               --name "riak${index}" \
               -d junsumida/docker-riak > /dev/null 2>&1
  fi
  echo -n "Starting riak${index}: "

  CONTAINER_ID=$(docker ps | grep "riak${index}" | cut -d" " -f1)
  CONTAINER_PORT=$(docker port "${CONTAINER_ID}" 8098 | cut -d ":" -f2)
  CONTAINER_IP_ADDRESS=$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' ${CONTAINER_ID})

  until curl -m 1 -s "http://${CLEAN_DOCKER_HOST}:${CONTAINER_PORT}/ping" | grep "OK" > /dev/null 2>&1;
  do
    echo -n "."
    sleep 3
  done

  if [ "${index}" -eq "1" ] ; then
    # remember the node name so that other intances can join it
    NODE_NAME="riak@${CONTAINER_IP_ADDRESS}"
  else
    # join the cluster
    docker exec ${CONTAINER_ID} riak-admin cluster join "${NODE_NAME}" > /dev/null 2>&1
  fi

  # if it's the last container to start, commit cluster changes
  if [ "${index}" -eq "${DOCKER_RIAK_CLUSTER_SIZE}" ] ; then
    docker exec ${CONTAINER_ID} riak-admin cluster plan > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin cluster commit > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type create maps     '{"props":{"datatype":"map"}}'     > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type create sets     '{"props":{"datatype":"set"}}'     > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type create counters '{"props":{"datatype":"counter"}}' > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type create bitcask_backend '{"props":{"riak_kv_multi_backend":"bitcask"}}' > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type create leveldb_backend '{"props":{"backend":"leveldb"}}'
    docker exec ${CONTAINER_ID} riak-admin bucket-type activate maps     > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type activate sets     > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type activate counters > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type activate bitcask_backend > /dev/null 2>&1
    docker exec ${CONTAINER_ID} riak-admin bucket-type activate leveldb_backend > /dev/null 2>&1
  fi

  echo " Complete"
done

echo
echo "Please wait approximately 30 seconds for the cluster to stabilize."
echo
