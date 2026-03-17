#!/bin/bash
set -e
mkdir -p /Users/Shared/flowtree/tools
cp /Users/worker/Projects/onyx/.build/debug/OnyxMCP /Users/Shared/flowtree/tools/OnyxMCP
chmod +x /Users/Shared/flowtree/tools/OnyxMCP
echo "Installed OnyxMCP to /Users/Shared/flowtree/tools/OnyxMCP"
