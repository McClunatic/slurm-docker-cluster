#!/bin/bash
set -e

# Test suite for the prometheus profile (Prometheus + Pushgateway + Grafana)
# Run with: ./test_prometheus.sh
# Requires: docker compose --profile prometheus up -d

CI_MODE=${CI:-false}

if [ "$CI_MODE" = "true" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

print_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
    TESTS_RUN=$((TESTS_RUN + 1))
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Test 1: Check if Prometheus is running
test_prometheus_running() {
    print_test "Checking if Prometheus is running..."

    if docker compose ps prometheus 2>/dev/null | grep -q "Up"; then
        print_pass "Prometheus is running"
    else
        print_fail "Prometheus is not running"
        return 1
    fi
}

# Test 2: Check Prometheus health
test_prometheus_healthy() {
    print_test "Checking Prometheus health..."

    HEALTH=$(docker exec prometheus wget -qO- http://localhost:9090/-/healthy 2>/dev/null || echo "unhealthy")

    if [ "$HEALTH" = "Healthy" ]; then
        print_pass "Prometheus is healthy"
    else
        print_fail "Prometheus is unhealthy (status: $HEALTH)"
        return 1
    fi
}

# Test 3: Check if Pushgateway is running
test_pushgateway_running() {
    print_test "Checking if Pushgateway is running..."

    if docker compose ps pushgateway 2>/dev/null | grep -q "Up"; then
        print_pass "Pushgateway is running"
    else
        print_fail "Pushgateway is not running"
        return 1
    fi
}

# Test 4: Check Pushgateway health
test_pushgateway_healthy() {
    print_test "Checking Pushgateway health..."

    HEALTH=$(docker exec pushgateway wget -qO- http://localhost:9091/-/healthy 2>/dev/null || echo "unhealthy")

    if [ "$HEALTH" = "Healthy" ]; then
        print_pass "Pushgateway is healthy"
    else
        print_fail "Pushgateway is unhealthy (status: $HEALTH)"
        return 1
    fi
}

# Test 5: Check if Grafana is running
test_grafana_running() {
    print_test "Checking if Grafana is running..."

    if docker compose ps grafana 2>/dev/null | grep -q "Up"; then
        print_pass "Grafana is running"
    else
        print_fail "Grafana is not running"
        return 1
    fi
}

# Test 6: Check Grafana health
test_grafana_healthy() {
    print_test "Checking Grafana API status..."

    # Grafana health endpoint returns JSON
    STATUS=$(docker exec grafana wget -qO- http://localhost:3000/api/health 2>/dev/null | grep -o '"database":"ok"' || echo "")

    if [ -n "$STATUS" ]; then
        print_pass "Grafana is available"
    else
        print_fail "Grafana is not available"
        return 1
    fi
}

# Test 7: Check Slurm PrometheusExporter configuration
test_slurm_prometheus_config() {
    print_test "Checking Slurm PrometheusExporter configuration..."

    PROM_EXPORTER=$(docker exec slurmctld grep "^PrometheusExporter" /etc/slurm/slurm.conf | cut -d= -f2 || echo "No")
    PROM_PORT=$(docker exec slurmctld grep "^PrometheusPort" /etc/slurm/slurm.conf | cut -d= -f2 || echo "")

    if [ "$PROM_EXPORTER" = "Yes" ]; then
        print_info "  PrometheusExporter=$PROM_EXPORTER"
        print_info "  PrometheusPort=$PROM_PORT"
        print_pass "Slurm configured for PrometheusExporter"
    else
        print_fail "Slurm not configured for PrometheusExporter (PrometheusExporter=$PROM_EXPORTER)"
        return 1
    fi
}

# Test 8: Check PrometheusExporter endpoint accessibility
test_prometheus_exporter_endpoint() {
    print_test "Checking PrometheusExporter endpoint..."

    # Wait a moment for slurmctld to fully start
    sleep 2

    # Try to access metrics endpoint
    METRICS=$(docker exec slurmctld curl -s http://localhost:8081/metrics 2>/dev/null | head -5)

    if echo "$METRICS" | grep -q "slurm_"; then
        print_info "  Sample metrics: $(echo "$METRICS" | grep "^slurm_" | head -1)"
        print_pass "PrometheusExporter endpoint is accessible"
    else
        print_fail "PrometheusExporter endpoint is not accessible or not returning metrics"
        print_info "  Response: $METRICS"
        return 1
    fi
}

# Test 9: Check Prometheus scraping Slurm metrics
test_prometheus_scraping_slurm() {
    print_test "Checking if Prometheus is scraping Slurm metrics..."

    # Give Prometheus time to scrape
    sleep 5

    # Query Prometheus for any Slurm metric
    RESPONSE=$(curl -s -G --data-urlencode "query=slurm_node_info" "http://localhost:9090/api/v1/query" 2>/dev/null)
    STATUS=$(echo "$RESPONSE" | jq -r '.status' 2>/dev/null || echo "error")
    RESULT_COUNT=$(echo "$RESPONSE" | jq -r '.data.result | length' 2>/dev/null || echo "0")

    if [ "$STATUS" = "success" ] && [ "$RESULT_COUNT" -gt 0 ]; then
        print_info "  Found $RESULT_COUNT node(s) in Slurm metrics"
        print_pass "Prometheus is successfully scraping Slurm metrics"
    else
        print_fail "Prometheus is not scraping Slurm metrics or no data available yet"
        print_info "  Status: $STATUS, Results: $RESULT_COUNT"
        return 1
    fi
}

# Test 10: Test application metrics submission
test_application_metrics() {
    print_test "Testing application metrics submission to Pushgateway..."

    # Submit a test job that pushes metrics
    print_info "  Submitting test job..."
    JOB_ID=$(docker exec slurmctld sbatch --wait /data/examples/jobs/prometheus_demo.sh 2>&1 | grep -oP '(?<=Submitted batch job )\d+' || echo "")

    if [ -z "$JOB_ID" ]; then
        print_fail "Failed to submit test job"
        return 1
    fi

    print_info "  Job ID: $JOB_ID"
    print_info "  Waiting for job to complete..."

    # Wait for job completion (with timeout)
    for i in {1..60}; do
        JOB_STATE=$(docker exec slurmctld squeue -j "$JOB_ID" -h -o "%T" 2>/dev/null || echo "COMPLETED")
        if [ "$JOB_STATE" = "COMPLETED" ] || [ -z "$JOB_STATE" ]; then
            break
        fi
        sleep 2
    done

    # Give Prometheus time to scrape Pushgateway
    sleep 5

    # Check if metrics appear in Prometheus
    RESPONSE=$(curl -s -G --data-urlencode "query=app_job_executions_total" "http://localhost:9090/api/v1/query" 2>/dev/null)
    STATUS=$(echo "$RESPONSE" | jq -r '.status' 2>/dev/null || echo "error")
    RESULT_COUNT=$(echo "$RESPONSE" | jq -r '.data.result | length' 2>/dev/null || echo "0")

    if [ "$STATUS" = "success" ] && [ "$RESULT_COUNT" -gt 0 ]; then
        print_info "  Found $RESULT_COUNT application metric(s)"
        print_pass "Application metrics successfully pushed and scraped"
    else
        print_fail "Application metrics not found in Prometheus"
        print_info "  Status: $STATUS, Results: $RESULT_COUNT"
        return 1
    fi
}

# Test 11: Test Prometheus query functionality
test_prometheus_queries() {
    print_test "Testing Prometheus query functionality..."

    # Test a few basic queries
    QUERIES=(
        "up"
        "slurm_jobs_total"
        "app_job_executions_total"
    )

    SUCCESS_COUNT=0
    for query in "${QUERIES[@]}"; do
        RESPONSE=$(curl -s -G --data-urlencode "query=$query" "http://localhost:9090/api/v1/query" 2>/dev/null)
        STATUS=$(echo "$RESPONSE" | jq -r '.status' 2>/dev/null || echo "error")
        if [ "$STATUS" = "success" ]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        fi
    done

    if [ "$SUCCESS_COUNT" -eq ${#QUERIES[@]} ]; then
        print_pass "All ${#QUERIES[@]} test queries executed successfully"
    else
        print_fail "Only $SUCCESS_COUNT/${#QUERIES[@]} queries succeeded"
        return 1
    fi
}

# Test 12: Check Grafana datasource
test_grafana_datasource() {
    print_test "Checking Grafana datasource configuration..."

    # Wait for Grafana to fully start
    sleep 3

    # Check if Prometheus datasource is configured
    DATASOURCES=$(docker exec grafana wget -qO- --header="Content-Type: application/json" \
        http://admin:admin@localhost:3000/api/datasources 2>/dev/null | jq -r '.[].type' 2>/dev/null || echo "")

    if echo "$DATASOURCES" | grep -q "prometheus"; then
        print_pass "Grafana has Prometheus datasource configured"
    else
        print_fail "Grafana does not have Prometheus datasource configured"
        return 1
    fi
}

# Main test execution
main() {
    print_header "Prometheus Profile Test Suite"
    echo ""
    echo "Testing Prometheus monitoring stack:"
    echo "  - Prometheus (metrics storage & querying)"
    echo "  - Pushgateway (application metrics)"
    echo "  - Grafana (visualization)"
    echo "  - Slurm PrometheusExporter"
    echo ""

    # Run all tests
    test_prometheus_running || true
    echo ""
    test_prometheus_healthy || true
    echo ""
    test_pushgateway_running || true
    echo ""
    test_pushgateway_healthy || true
    echo ""
    test_grafana_running || true
    echo ""
    test_grafana_healthy || true
    echo ""
    test_slurm_prometheus_config || true
    echo ""
    test_prometheus_exporter_endpoint || true
    echo ""
    test_prometheus_scraping_slurm || true
    echo ""
    test_application_metrics || true
    echo ""
    test_prometheus_queries || true
    echo ""
    test_grafana_datasource || true
    echo ""

    # Print summary
    print_header "Test Summary"
    echo ""
    echo "Tests run:    $TESTS_RUN"
    echo -e "${GREEN}Tests passed: $TESTS_PASSED${NC}"
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}Tests failed: $TESTS_FAILED${NC}"
        echo ""
        echo "To troubleshoot:"
        echo "  - Check logs: make logs-prometheus"
        echo "  - Check Prometheus targets: http://localhost:9090/targets"
        echo "  - Check Pushgateway metrics: http://localhost:9091/metrics"
        echo "  - Check Grafana: http://localhost:3000 (admin/admin)"
        exit 1
    else
        echo -e "${GREEN}Tests failed: $TESTS_FAILED${NC}"
        echo ""
        echo "✓ All tests passed!"
        echo ""
        echo "Access the monitoring stack:"
        echo "  - Prometheus: http://localhost:9090"
        echo "  - Pushgateway: http://localhost:9091"
        echo "  - Grafana: http://localhost:3000 (admin/admin)"
        echo ""
        echo "Try the query demo scripts:"
        echo "  - ./examples/prometheus/query_slurm_metrics.sh"
        echo "  - ./examples/prometheus/query_app_metrics.sh"
    fi
}

# Run main function
main
