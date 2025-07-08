#!/bin/bash

# Function to check if Redis is running on a port
wait_for_redis() {
    local port=$1
    local max_attempts=30
    local attempt=1

    echo "Waiting for Redis on port $port to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if redis-cli -p $port ping > /dev/null 2>&1; then
            echo "Redis on port $port is ready!"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts: Redis on port $port not ready yet..."
        # Check if the process is actually running
        if ! pgrep -f "redis-server.*$port" > /dev/null; then
            echo "Redis server process for port $port is not running!"
            echo "Last few lines of startup log:"
            tail -n 20 redis-$port/startup.log
            return 1
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    echo "Redis on port $port failed to start after $max_attempts attempts"
    echo "Last few lines of startup log:"
    tail -n 20 redis-$port/startup.log
    return 1
}

# Function to check cluster status
check_cluster_status() {
    local port=$1
    local max_attempts=60
    local attempt=1

    echo "Waiting for cluster to be ready..."
    while [ $attempt -le $max_attempts ]; do
        local cluster_info=$(redis-cli -p $port cluster info)
        echo "Current cluster state:"
        echo "$cluster_info"

        if echo "$cluster_info" | grep -q "cluster_state:ok" && \
           echo "$cluster_info" | grep -q "cluster_known_nodes:6" && \
           echo "$cluster_info" | grep -q "cluster_size:3"; then
            echo "Cluster is ready!"
            return 0
        fi

        echo "Attempt $attempt/$max_attempts: Cluster not ready yet..."
        echo "Cluster nodes:"
        redis-cli -p $port cluster nodes

        sleep 2
        attempt=$((attempt + 1))
    done
    echo "Cluster failed to stabilize after $max_attempts attempts"
    return 1
}

# Clean up any existing Redis instances
echo "Cleaning up any existing Redis instances..."
for port in 7001 7002 7003 7004 7005 7006; do
    redis-cli -p $port shutdown > /dev/null 2>&1
    # Kill any remaining Redis processes on these ports
    lsof -ti :$port | xargs kill -9 2>/dev/null || true
    # Remove any existing cluster configuration
    rm -f redis-$port/nodes-*.conf
done

# Create directories for Redis instances
echo "Creating Redis configuration directories..."
for port in 7001 7002 7003 7004 7005 7006; do
    mkdir -p redis-$port
    cat > redis-$port/redis.conf << EOF
port $port
cluster-enabled yes
cluster-config-file nodes-$port.conf
cluster-node-timeout 5000
appendonly no
dir ./
bind 127.0.0.1
daemonize no
logfile "redis-$port.log"
loglevel debug
cluster-announce-ip 127.0.0.1
cluster-announce-port $port
cluster-announce-bus-port 1$port
save ""
appendfilename "appendonly-$port.aof"
EOF
done

# Start Redis instances
echo "Starting Redis instances..."
for port in 7001 7002 7003 7004 7005 7006; do
    echo "Starting Redis on port $port..."
    # Start Redis in the background and capture both stdout and stderr
    redis-server redis-$port/redis.conf > redis-$port/startup.log 2>&1 &
    REDIS_PID=$!

    # Wait a moment to see if Redis starts successfully
    sleep 2

    # Check if the process is still running
    if ! kill -0 $REDIS_PID 2>/dev/null; then
        echo "Redis failed to start on port $port. Check the log file:"
        cat redis-$port/startup.log
        exit 1
    fi

    if ! wait_for_redis $port; then
        echo "Failed to start Redis on port $port. Check the log file:"
        cat redis-$port/startup.log
        exit 1
    fi
done

echo "All Redis instances are running. Creating cluster..."

# First, ensure all nodes know about each other
echo "Ensuring all nodes know about each other..."
for port in 7002 7003 7004 7005 7006; do
    echo "Connecting node $port to cluster..."
    redis-cli -p $port cluster meet 127.0.0.1 7001
    sleep 1
done

# Wait for nodes to discover each other
echo "Waiting for nodes to discover each other..."
sleep 5

# Create the cluster with proper master-slave distribution
echo "Creating Redis cluster..."
redis-cli --cluster create \
    127.0.0.1:7001 \
    127.0.0.1:7002 \
    127.0.0.1:7003 \
    127.0.0.1:7004 \
    127.0.0.1:7005 \
    127.0.0.1:7006 \
    --cluster-replicas 1 \
    --cluster-yes

# Wait for cluster to stabilize
echo "Waiting for cluster to stabilize..."
sleep 10

# Verify and fix cluster configuration if needed
echo "Verifying cluster configuration..."
cluster_nodes=$(redis-cli -p 7001 cluster nodes)
master_count=$(echo "$cluster_nodes" | grep "master" | wc -l)

if [ "$master_count" -ne 3 ]; then
    echo "Fixing cluster configuration..."
    # Flush all data and reset cluster configuration
    for port in 7001 7002 7003 7004 7005 7006; do
        echo "Flushing data on port $port..."
        redis-cli -p $port FLUSHALL
        echo "Resetting cluster on port $port..."
        redis-cli -p $port CLUSTER RESET
    done

    # Recreate cluster with proper distribution
    redis-cli --cluster create \
        127.0.0.1:7001 \
        127.0.0.1:7002 \
        127.0.0.1:7003 \
        127.0.0.1:7004 \
        127.0.0.1:7005 \
        127.0.0.1:7006 \
        --cluster-replicas 1 \
        --cluster-yes

    sleep 10
fi

# Check cluster status
echo "Checking cluster status..."
if ! check_cluster_status 7001; then
    echo "Cluster failed to stabilize. Current status:"
    redis-cli -p 7001 cluster info
    echo "Cluster nodes:"
    redis-cli -p 7001 cluster nodes
    echo "Redis logs:"
    for port in 7001 7002 7003 7004 7005 7006; do
        echo "=== Redis $port logs ==="
        cat redis-$port/startup.log
    done
    exit 1
fi

echo "Cluster is ready! Final status:"
redis-cli -p 7001 cluster info
echo "Cluster nodes:"
redis-cli -p 7001 cluster nodes
