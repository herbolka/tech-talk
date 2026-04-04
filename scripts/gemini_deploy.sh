#!/bin/bash
set -e

echo "Starting AI agent deploy..."
echo "Model: gemini-2.5-flash-lite"
echo ""

gemini -m gemini-2.5-flash-lite -p "
Deploy the currency-conversion-service following the steps in GEMINI.md exactly.
Start from Step 1 and execute each step in order.
Do not ask for confirmation — execute all commands directly.
Report final status: DEPLOYED or FAILED with reason.
"