#!/bin/bash
set -e

# Test suite for the metrics profile (Prometheus + Grafana + Pushgateway)
# Run with: ./test_metrics.sh
# Requires: docker compose --profile metrics up -d
# Metrics support: Slurm 25.11.2+

CI_MODE=${CI:-false}

# Colors for output (disabled in CI for better log readability)
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
    NC='\033[0m' # No Color
fi

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Print functions
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

# Retry curl with exponential backoff
# Usage: retry_curl <url> [max_attempts=5]
retry_curl() {
    local url="$1"
    local max_attempts="${2:-5}"
    local attempt=1
    local delay=1

    while [ $attempt -le $max_attempts ]; do
        if curl -sf --max-time 5 "$url" 2>/dev/null; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            sleep "$delay"
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

# Wait for Prometheus scrape cycle (up to 90 seconds)
# Metrics may take 60s scrape interval + startup variance
wait_for_scrape_cycle() {
    local max_wait=90
    local elapsed=0
    local interval=2

    print_info "Waiting for metrics scrape cycle (max ${max_wait}s)..."

    while [ $elapsed -lt $max_wait ]; do
        if curl -sf --max-time 5 "http://prometheus:9090/-/healthy" >/dev/null 2>&1; then
            sleep "$interval"
            return 0
        fi

        elapsed=$((elapsed + interval))
        sleep "$interval"
    done

    print_info "Prometheus available, allowing time for first scrape cycle..."
    sleep 10
    return 0
}

# ============================================================================
# Tier 1: Infrastructure Tests (container health and port accessibility)
# ============================================================================

test_prometheus_running() {
    print_test "Checking if Prometheus is running..."

    if docker compose ps prometheus 2>/dev/null | grep -q "Up"; then
        print_pass "Prometheus is running"
        return 0
    else
        print_fail "Prometheus is not running"
        return 1
    fi
}

test_prometheus_healthy() {
    print_test "Checking Prometheus health endpoint..."

    if retry_curl "http://prometheus:9090/-/healthy" 5 >/dev/null 2>&1; then
        print_pass "Prometheus is healthy"
        return 0
    else
        print_fail "Prometheus is not responding to health checks"
        return 1
    fi
}

test_pushgateway_running() {
    print_test "Checking if Pushgateway is running..."

    if docker compose ps pushgateway 2>/dev/null | grep -q "Up"; then
        print_pass "Pushgateway is running"
        return 0
    else
        print_fail "Pushgateway is not running"
        return 1
    fi
}

test_pushgateway_healthy() {
    print_test "Checking Pushgateway health endpoint..."

    if retry_curl "http://pushgateway:9091/-/healthy" 5 >/dev/null 2>&1; then
        print_pass "Pushgateway is healthy"
        return 0
    else
        print_fail "Pushgateway is not responding to health checks"
        return 1
    fi
}

test_grafana_running() {
    print_test "Checking if Grafana is running..."

    if docker compose ps grafana 2>/dev/null | grep -q "Up"; then
        print_pass "Grafana is running"
        return 0
    else
        print_fail "Grafana is not running"
        return 1
    fi
}

test_grafana_healthy() {
    print_test "Checking Grafana health API..."

    if retry_curl "http://grafana:3000/api/health" 5 >/dev/null 2>&1; then
        print_pass "Grafana is healthy"
        return 0
    else
        print_fail "Grafana is not responding to health checks"
        return 1
    fi
}

# ============================================================================
# Tier 2: Configuration Tests (verify target/datasource/dashboard setup)
# ============================================================================

test_prometheus_targets() {
    print_test "Checking Prometheus scrape targets configuration..."

    # Give Prometheus a moment to fully initialize
    wait_for_scrape_cycle

    local targets_json
    targets_json=$(curl -sf --max-time 10 "http://prometheus:9090/api/v1/targets" 2>/dev/null)

    if [ -z "$targets_json" ]; then
        print_fail "Failed to retrieve Prometheus targets"
        return 1
    fi

    # Use jq to parse JSON and count targets
    local active_count
    active_count=$(echo "$targets_json" | jq '.data.activeTargets | length' 2>/dev/null || echo "0")

    if [ "$active_count" -lt 4 ]; then
        print_fail "Expected at least 4 scrape targets, found $active_count"
        echo "$targets_json" | jq '.data.activeTargets[].job' 2>/dev/null || true
        return 1
    fi

    # Verify targets are in "up" state
    local up_count
    up_count=$(echo "$targets_json" | jq '[.data.activeTargets[] | select(.health == "up")] | length' 2>/dev/null || echo "0")

    if [ "$up_count" -lt 4 ]; then
        print_fail "Not all targets are healthy (up: $up_count/$active_count)"
        echo "$targets_json" | jq '.data.activeTargets[] | {job: .job, health: .health}' 2>/dev/null || true
        return 1
    fi

    print_pass "All $up_count scrape targets are configured and healthy"
    return 0
}

test_grafana_datasource_configured() {
    print_test "Checking Grafana Prometheus datasource configuration..."

    local datasources_json
    datasources_json=$(curl -sf --max-time 10 "http://grafana:3000/api/datasources" 2>/dev/null)

    if [ -z "$datasources_json" ]; then
        print_fail "Failed to retrieve Grafana datasources"
        return 1
    fi

    # Use jq to find Prometheus datasource
    local prometheus_ds
    prometheus_ds=$(echo "$datasources_json" | jq '.[] | select(.type == "prometheus")' 2>/dev/null)

    if [ -z "$prometheus_ds" ]; then
        print_fail "Prometheus datasource not found in Grafana"
        echo "$datasources_json" | jq '.[] | {name: .name, type: .type}' 2>/dev/null || true
        return 1
    fi

    # Verify datasource is healthy
    local ds_health
    ds_health=$(echo "$prometheus_ds" | jq -r '.health // "unknown"' 2>/dev/null)

    if [ "$ds_health" != "ok" ] && [ "$ds_health" != "true" ]; then
        print_info "Datasource health: $ds_health (may not be fully initialized yet)"
    fi

    # Verify datasource URL is correct
    local ds_url
    ds_url=$(echo "$prometheus_ds" | jq -r '.url' 2>/dev/null)

    if [[ "$ds_url" == *"prometheus"* ]]; then
        print_pass "Prometheus datasource is configured (URL: $ds_url)"
        return 0
    else
        print_fail "Prometheus datasource URL is incorrect: $ds_url"
        return 1
    fi
}

test_grafana_dashboard_provisioned() {
    print_test "Checking Grafana SLURM dashboard provisioning..."

    local dashboards_json
    dashboards_json=$(curl -sf --max-time 10 "http://grafana:3000/api/search" 2>/dev/null)

    if [ -z "$dashboards_json" ]; then
        print_fail "Failed to retrieve Grafana dashboards"
        return 1
    fi

    # Use jq to search for SLURM dashboard
    local slurm_dashboard
    slurm_dashboard=$(echo "$dashboards_json" | jq '.[] | select(.title | contains("slurm") or contains("SLURM"))' 2>/dev/null)

    if [ -z "$slurm_dashboard" ]; then
        print_fail "SLURM dashboard not found in Grafana"
        print_info "Available dashboards:"
        echo "$dashboards_json" | jq '.[] | .title' 2>/dev/null | head -5 || true
        return 1
    fi

    local dashboard_title
    dashboard_title=$(echo "$slurm_dashboard" | jq -r '.title' 2>/dev/null)

    print_pass "SLURM dashboard is provisioned: $dashboard_title"
    return 0
}

# ============================================================================
# Tier 3: Integration Tests (verify metrics are being collected)
# ============================================================================

test_slurm_metrics_available() {
    print_test "Testing SLURM metrics collection..."

    # Submit a test job without --wait so we can poll its status
    local job_id
    job_id=$(docker exec slurmctld bash -c "cd /data && sbatch --wrap='echo metrics_test' 2>&1" | grep -oP '\d+' | head -1)

    if [ -z "$job_id" ]; then
        print_fail "Failed to submit test job"
        return 1
    fi

    print_info "Submitted job $job_id, waiting for completion..."

    # Poll job status (max 30s)
    local elapsed=0
    local max_wait=30

    while [ $elapsed -lt $max_wait ]; do
        local job_state
        job_state=$(docker exec slurmctld scontrol show job "$job_id" 2>/dev/null | grep "JobState=" | grep -oP 'JobState=\K\w+')

        if [ "$job_state" = "COMPLETED" ]; then
            print_info "Job $job_id completed"
            break
        elif [ "$job_state" = "FAILED" ] || [ "$job_state" = "CANCELLED" ]; then
            print_fail "Job $job_id failed with state: $job_state"
            return 1
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ $elapsed -ge $max_wait ]; then
        print_fail "Job $job_id did not complete within ${max_wait}s"
        return 1
    fi

    # Wait for metrics to be scraped
    print_info "Job completed, waiting for metrics scrape cycle..."
    sleep 10

    # Query Prometheus for SLURM metrics
    local metrics_json
    metrics_json=$(curl -sf --max-time 10 "http://prometheus:9090/api/v1/query?query=slurm_job_count" 2>/dev/null)

    if [ -z "$metrics_json" ]; then
        print_fail "Failed to query Prometheus for SLURM metrics"
        return 1
    fi

    # Use jq to verify metrics exist and have labels
    local result_count
    result_count=$(echo "$metrics_json" | jq '.data.result | length' 2>/dev/null || echo "0")

    if [ "$result_count" -eq 0 ]; then
        print_fail "No slurm_job_count metrics found in Prometheus"
        return 1
    fi

    # Verify labels exist
    local has_labels
    has_labels=$(echo "$metrics_json" | jq '.data.result[0].metric | keys | length' 2>/dev/null || echo "0")

    if [ "$has_labels" -eq 0 ]; then
        print_fail "SLURM metrics have no labels"
        return 1
    fi

    # Verify 'cluster' label exists
    local has_cluster_label
    has_cluster_label=$(echo "$metrics_json" | jq '.data.result[0].metric | has("cluster")' 2>/dev/null)

    if [ "$has_cluster_label" != "true" ]; then
        print_fail "SLURM metrics missing 'cluster' label"
        return 1
    fi

    print_pass "SLURM metrics are being collected (slurm_job_count with labels)"
    return 0
}

test_pushgateway_metrics_push() {
    print_test "Testing Pushgateway metrics push and scrape..."

    # Create a test metric
    local test_metric='test_metric_slurm{job="test_job"} 42'

    # Push metric to Pushgateway
    if ! echo "$test_metric" | curl -sf --max-time 10 -X POST --data-binary @- "http://pushgateway:9091/metrics/job/test_job" >/dev/null 2>&1; then
        print_fail "Failed to push metrics to Pushgateway"
        return 1
    fi

    print_info "Pushed test metric to Pushgateway"

    # Verify metric was stored in Pushgateway
    local pg_response
    pg_response=$(curl -sf --max-time 10 "http://pushgateway:9091/metrics/job/test_job" 2>/dev/null)

    if [ -z "$pg_response" ]; then
        print_fail "Failed to retrieve metrics from Pushgateway"
        return 1
    fi

    if ! echo "$pg_response" | grep -q "test_metric"; then
        print_fail "Test metric not found in Pushgateway"
        return 1
    fi

    print_info "Test metric stored in Pushgateway"

    # Wait for Prometheus to scrape Pushgateway
    print_info "Waiting for Prometheus to scrape Pushgateway..."
    sleep 5

    # Query Prometheus for the test metric
    local prom_query
    prom_query=$(curl -sf --max-time 10 "http://prometheus:9090/api/v1/query?query=test_metric_slurm" 2>/dev/null)

    if [ -z "$prom_query" ]; then
        print_fail "Failed to query Prometheus for test metric"
        # Cleanup anyway
        curl -X DELETE "http://pushgateway:9091/metrics/job/test_job" >/dev/null 2>&1 || true
        return 1
    fi

    # Use jq to check if metric was scraped
    local metric_found
    metric_found=$(echo "$prom_query" | jq '.data.result | length' 2>/dev/null || echo "0")

    # Cleanup test metric from Pushgateway
    curl -X DELETE "http://pushgateway:9091/metrics/job/test_job" >/dev/null 2>&1 || true

    if [ "$metric_found" -gt 0 ]; then
        print_pass "Test metric was pushed to Pushgateway and scraped by Prometheus"
        return 0
    else
        print_fail "Test metric not found in Prometheus after scrape"
        return 1
    fi
}

# ============================================================================
# Main test execution
# ============================================================================

main() {
    print_header "Metrics Profile Test Suite"

    if [ "$CI_MODE" = "true" ]; then
        print_info "Running in CI mode"
    fi

    echo ""

    # Tier 1: Infrastructure tests
    print_header "Tier 1: Infrastructure Tests"
    test_prometheus_running || true
    test_prometheus_healthy || true
    test_pushgateway_running || true
    test_pushgateway_healthy || true
    test_grafana_running || true
    test_grafana_healthy || true

    echo ""

    # Tier 2: Configuration tests
    print_header "Tier 2: Configuration Tests"
    test_prometheus_targets || true
    test_grafana_datasource_configured || true
    test_grafana_dashboard_provisioned || true

    echo ""

    # Tier 3: Integration tests
    print_header "Tier 3: Integration Tests"
    test_slurm_metrics_available || true
    test_pushgateway_metrics_push || true

    echo ""
    print_header "Test Summary"
    echo -e "Tests Run:    ${BLUE}$TESTS_RUN${NC}"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main
