#!/bin/bash
# Query Slurm Metrics from Prometheus
#
# This script demonstrates how to query Slurm cluster metrics
# from Prometheus using the HTTP API and PromQL queries.
#
# Usage: ./query_slurm_metrics.sh

set -e

PROMETHEUS_URL="http://localhost:9090"
API_URL="${PROMETHEUS_URL}/api/v1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_query() {
    echo -e "${YELLOW}Query:${NC} $1"
}

print_result() {
    echo -e "${GREEN}Result:${NC}"
}

execute_query() {
    local query="$1"
    local description="$2"
    
    print_header "$description"
    print_query "$query"
    echo ""
    
    # Execute query and pretty-print results
    local response=$(curl -s -G --data-urlencode "query=$query" "${API_URL}/query")
    
    # Check if query was successful
    local status=$(echo "$response" | jq -r '.status')
    if [ "$status" != "success" ]; then
        echo -e "${RED}Error executing query${NC}"
        echo "$response" | jq .
        return 1
    fi
    
    print_result
    echo "$response" | jq -r '.data.result[] | 
        "  Metric: \(.metric | to_entries | map("\(.key)=\(.value)") | join(", "))\n  Value: \(.value[1])"'
    
    if [ "${PIPESTATUS[1]}" -ne 0 ]; then
        echo "  No data available"
    fi
}

# Check if Prometheus is accessible
if ! curl -s "${PROMETHEUS_URL}/-/healthy" > /dev/null 2>&1; then
    echo -e "${RED}Error: Prometheus is not accessible at ${PROMETHEUS_URL}${NC}"
    echo "Make sure Prometheus is running with: make up (with PROMETHEUS_ENABLE=true in .env)"
    exit 1
fi

echo "========================================="
echo "Slurm Metrics Query Demonstration"
echo "========================================="
echo "Prometheus: ${PROMETHEUS_URL}"
echo "API: ${API_URL}"
echo ""
echo "This script demonstrates various PromQL queries for Slurm metrics"
echo "exposed by the PrometheusExporter plugin."
echo ""

# Wait a moment for metrics to be available
sleep 2

# Query 1: Total number of nodes
execute_query \
    'count(slurm_node_info)' \
    "Total Number of Compute Nodes"

# Query 2: Nodes by state
execute_query \
    'count by (state) (slurm_node_info)' \
    "Nodes Grouped by State"

# Query 3: Total CPUs in cluster
execute_query \
    'sum(slurm_node_cpus_total)' \
    "Total CPUs in Cluster"

# Query 4: Available (idle) CPUs
execute_query \
    'sum(slurm_node_cpus_idle)' \
    "Available (Idle) CPUs"

# Query 5: CPU utilization percentage
execute_query \
    '100 * (1 - (sum(slurm_node_cpus_idle) / sum(slurm_node_cpus_total)))' \
    "Cluster CPU Utilization (%)"

# Query 6: Total jobs in various states
execute_query \
    'slurm_jobs_total' \
    "Total Jobs (All States)"

# Query 7: Running jobs
execute_query \
    'slurm_jobs_running' \
    "Currently Running Jobs"

# Query 8: Pending jobs
execute_query \
    'slurm_jobs_pending' \
    "Pending Jobs in Queue"

# Query 9: Completed jobs (rate over last 5 minutes)
execute_query \
    'rate(slurm_jobs_completed_total[5m])' \
    "Job Completion Rate (jobs/sec, 5min avg)"

# Query 10: Partition information
execute_query \
    'slurm_partition_info' \
    "Partition Information"

# Query 11: Jobs by partition
execute_query \
    'sum by (partition) (slurm_partition_jobs_running)' \
    "Running Jobs per Partition"

# Query 12: Scheduler information
execute_query \
    'slurm_scheduler_info' \
    "Scheduler Status"

print_header "Query Examples Complete"
echo ""
echo "To explore metrics interactively:"
echo "  1. Open Prometheus web UI: ${PROMETHEUS_URL}"
echo "  2. Go to Graph tab"
echo "  3. Try queries from this script or explore available metrics"
echo ""
echo "Available metric prefixes:"
echo "  - slurm_node_*        : Node-level metrics"
echo "  - slurm_partition_*   : Partition metrics"
echo "  - slurm_jobs_*        : Job statistics"
echo "  - slurm_scheduler_*   : Scheduler information"
echo ""
echo "For more information on PromQL: https://prometheus.io/docs/prometheus/latest/querying/basics/"
echo ""
