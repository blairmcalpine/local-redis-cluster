#!/bin/bash

echo "Stopping Redis instances..."
for port in 7001 7002 7003 7004 7005 7006; do
    # Try graceful shutdown first
    redis-cli -p $port shutdown > /dev/null 2>&1
    # Force kill any remaining processes
    lsof -ti :$port | xargs kill -9 2>/dev/null || true
done

echo "Removing Redis data directories and files..."
for port in 7001 7002 7003 7004 7005 7006; do
    # Remove the entire directory
    rm -rf redis-$port
    # Remove any potential leftover files in the current directory
    rm -f nodes-$port.conf
    rm -f dump-$port.rdb
    rm -f appendonly-$port.aof
    rm -f redis-$port.log
    rm -f startup.log
done
rm -f dump.rdb

# Wait a moment to ensure all processes are stopped
sleep 2

echo "Checking for any remaining Redis processes..."
ps aux | grep redis-server | grep -v grep

echo "Redis instances and all data cleaned up!"
