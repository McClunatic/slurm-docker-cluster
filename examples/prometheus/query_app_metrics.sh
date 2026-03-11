#!/bin/bash
# Query Application Metrics from Prometheus
#
# This script demonstrates how to query custom application metrics
# that were pushed to Pushgateway and scraped by Prometheus.
#
# Usage: ./query_app_metrics.sh

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
        "  Labels: \(.metric | to_entries | map("\(.key)=\(.value)") | join(", "))\n  Value: \(.value[1])\n"'
    
    if [ "${PIPESTATUS[1]}" -ne 0 ]; then
        echo "  No data available yet"
        echo "  Run some demo jobs first: sbatch /data/examples/jobs/prometheus_demo.sh"
    fi
}

execute_table_query() {
    local query="$1"
    local description="$2"
    
    print_header "$description"
    print_query "$query"
    echo ""
    
    # Execute query and format as table
    local response=$(curl -s -G --data-urlencode "query=$query" "${API_URL}/query")
    
    # Check if query was successful
    local status=$(echo "$response" | jq -r '.status')
    if [ "$status" != "success" ]; then
        echo -e "${RED}Error executing query${NC}"
        echo "$response" | jq .
        return 1
    fi
    
    print_result
    # Format as simple table
    echo "$response" | jq -r '.data.result[] | 
        [.metric.app_name // "N/A", .metric.username // "N/A", .value[1]] | 
        @tsv' | awk 'BEGIN {printf "  %-20s %-15s %s\n", "Application", "User", "Value"; 
                            printf "  %-20s %-15s %s\n", "--------------------", "---------------", "-----"} 
                     {printf "  %-20s %-15s %s\n", $1, $2, $3}'
    
    if [ "${PIPESTATUS[1]}" -ne 0 ]; then
        echo "  No data available yet"
        echo "  Run some demo jobs first: sbatch /data/examples/jobs/prometheus_demo.sh"
    fi
}

# Check if Prometheus is accessible
if ! curl -s "${PROMETHEUS_URL}/-/healthy" > /dev/null 2>&1; then
    echo -e "${RED}Error: Prometheus is not accessible at ${PROMETHEUS_URL}${NC}"
    echo "Make sure Prometheus is running with: make up (with PROMETHEUS_ENABLE=true in .env)"
    exit 1
fi

echo "========================================="
echo "Application Metrics Query Demonstration"
echo "========================================="
echo "Prometheus: ${PROMETHEUS_URL}"
echo "API: ${API_URL}"
echo ""
echo "This script demonstrates various PromQL queries for custom"
echo "application metrics pushed via Pushgateway."
echo ""

# Wait a moment for metrics to be available
sleep 2

# Query 1: Total executions per application
execute_table_query \
    'sum by (app_name, username) (app_job_executions_total)' \
    "Total Job Executions by Application and User"

# Query 2: Average job duration by application
execute_table_query \
    'avg by (app_name) (app_job_duration_seconds)' \
    "Average Job Duration by Application (seconds)"

# Query 3: Most recent job duration per application
execute_query \
    'app_job_duration_seconds' \
    "Most Recent Job Duration (all applications)"

# Query 4: Total data processed per application
execute_table_query \
    'sum by (app_name, username) (app_data_processed_mb)' \
    "Total Data Processed by Application (MB)"

# Query 5: Total tasks completed per application
execute_table_query \
    'sum by (app_name) (app_tasks_completed_total)' \
    "Total Tasks Completed by Application"

# Query 6: Most active users
execute_table_query \
    'sum by (username) (app_job_executions_total)' \
    "Most Active Users (by job count)"

# Query 7: Applications by partition
execute_query \
    'count by (app_name, partition) (app_job_executions_total)' \
    "Application Usage by Partition"

# Query 8: Throughput - data processed per second
execute_query \
    'app_data_processed_mb / app_job_duration_seconds' \
    "Data Processing Throughput (MB/sec)"

# Query 9: Which applications are used most
execute_table_query \
    'topk(5, sum by (app_name) (app_job_executions_total))' \
    "Top 5 Most Used Applications"

# Query 10: All available application metrics
print_header "All Application Metric Names"
echo ""
curl -s "${API_URL}/label/__name__/values" | \
    jq -r '.data[] | select(startswith("app_"))' | \
    awk '{print "  - " $0}'

print_header "Query Examples Complete"
echo ""
echo "To generate more metrics, submit demo jobs:"
echo "  docker exec -it slurmctld bash"
echo "  cd /data"
echo "  sbatch examples/jobs/prometheus_demo.sh"
echo "  # Submit multiple times to see aggregated statistics"
echo ""
echo "To explore metrics interactively:"
echo "  1. Open Prometheus web UI: ${PROMETHEUS_URL}"
echo "  2. Go to Graph tab"
echo "  3. Try queries from this script or explore 'app_*' metrics"
echo ""
echo "To view raw metrics from Pushgateway:"
echo "  curl http://localhost:9091/metrics | grep app_"
echo ""
echo "Application metrics available:"
echo "  - app_job_executions_total  : Number of times each app was run"
echo "  - app_job_duration_seconds  : How long each job took"
echo "  - app_data_processed_mb     : Amount of data processed"
echo "  - app_tasks_completed_total : Number of tasks completed"
echo ""
