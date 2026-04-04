#!/bin/bash
set -e

NAMESPACE="production"

echo "Collecting deployment data..."

PODS=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null)
SVC=$(kubectl get svc -n "$NAMESPACE" -o json 2>/dev/null)
HPA=$(kubectl get hpa -n "$NAMESPACE" -o json 2>/dev/null)
LOGS=$(kubectl logs -n "$NAMESPACE" deployment/currency-conversion-service --tail=30 2>/dev/null || echo "no logs yet")

echo "$PODS $SVC $HPA $LOGS" | gemini -m gemini-2.5-flash-lite -p "
Analyze this Kubernetes deployment data and report:

1. Are all pods Running?
2. Does the LoadBalancer have an External IP?
3. Are there errors in the logs?
4. Is HPA reporting metrics?

Output:
STATUS: HEALTHY or UNHEALTHY
PODS: X/X running
EXTERNAL_IP: <value or pending>
ERRORS: none or list them
RECOMMENDATION: what to fix if unhealthy
"