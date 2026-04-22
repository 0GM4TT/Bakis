#!/bin/bash
set -e

echo "==> Shutting down worker nodes..."
ansible workers -a "sudo shutdown -h now" -b \
    --timeout 5 > /dev/null 2>&1 || true

echo "==> Waiting 30 seconds before shutting down master..."
sleep 30

echo "==> Shutting down master node..."
ansible master -a "sudo shutdown -h now" -b \
    --timeout 5 > /dev/null 2>&1 || true

echo "==> Cluster shutdown complete. All nodes are powering off."