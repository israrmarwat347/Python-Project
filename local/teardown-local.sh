#!/usr/bin/env bash
# Delete the whole local kind cluster. (Safe: AWS is not touched.)
set -euo pipefail
kind delete cluster --name devops-notes
echo "kind cluster 'devops-notes' deleted."
