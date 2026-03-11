# Prometheus Monitoring for Slurm Docker Cluster

This guide provides comprehensive documentation for using Prometheus, Pushgateway, and Grafana to monitor the Slurm cluster and track application usage metrics.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Components](#components)
- [Metrics Available](#metrics-available)
- [Query Examples](#query-examples)
- [Application Instrumentation](#application-instrumentation)
- [Grafana Dashboards](#grafana-dashboards)
- [Troubleshooting](#troubleshooting)

## Overview

The Prometheus monitoring stack provides:

1. **Slurm Cluster Metrics** - Exposed by Slurm's built-in PrometheusExporter plugin
2. **Application Metrics** - Custom metrics pushed by user applications via Pushgateway
3. **Visualization** - Pre-configured Grafana dashboards for monitoring and analysis

### Key Features

- ✅ Real-time cluster monitoring (nodes, jobs, partitions, resources)
- ✅ Job accounting and statistics
- ✅ Application usage tracking with custom metrics
- ✅ Historical trend analysis
- ✅ Pre-built Grafana dashboards
- ✅ PromQL query examples for common use cases

## Architecture

```
┌─────────────────┐
│   Slurm Cluster │
│   (slurmctld)   │──┐
│                 │  │ Exposes metrics
│ PrometheusExporter│  │ on port 8081
└─────────────────┘  │
                     │
┌─────────────────┐  │    ┌─────────────────┐
│ User Applications│──┼───▶│   Pushgateway   │
│  (jobs/scripts)  │  │    │   (Port 9091)   │
└─────────────────┘  │    └────────┬────────┘
                     │             │
                     │             │ Push metrics
                     ▼             ▼
                ┌────────────────────┐
                │    Prometheus      │
                │   (Port 9090)      │
                │                    │
                │ - Scrapes metrics  │
                │ - Stores time-series│
                │ - Provides queries │
                └─────────┬──────────┘
                          │
                          │ Query metrics
                          ▼
                ┌─────────────────┐
                │     Grafana      │
                │   (Port 3000)    │
                │                  │
                │ - Visualizations │
                │ - Dashboards     │
                │ - Alerts         │
                └──────────────────┘
```

## Quick Start

### 1. Enable Prometheus Profile

Edit `.env` file and add:

```bash
PROMETHEUS_ENABLE=true
```

### 2. Start the Cluster

```bash
make build
make up
```

The Prometheus profile will be automatically enabled, starting:
- Prometheus (metrics storage and querying)
- Pushgateway (for application metrics)
- Grafana (visualization)

### 3. Verify Services

```bash
# Check all services are running
docker compose ps

# Run test suite
make test-prometheus
```

### 4. Access Web Interfaces

- **Prometheus**: http://localhost:9090
- **Pushgateway**: http://localhost:9091
- **Grafana**: http://localhost:3000 (login: admin/admin)

### 5. Generate Sample Data

```bash
# Submit demo jobs to generate metrics
docker exec -it slurmctld bash
cd /data
sbatch examples/jobs/prometheus_demo.sh
# Submit multiple times to see aggregated data
```

### 6. Explore Metrics

```bash
# Query Slurm metrics
./examples/prometheus/query_slurm_metrics.sh

# Query application metrics
./examples/prometheus/query_app_metrics.sh
```

## Components

### Slurm PrometheusExporter

Slurm 25.11+ includes a built-in PrometheusExporter plugin that exposes cluster metrics in OpenMetrics/Prometheus format.

**Configuration** (in `slurm.conf`):
```
PrometheusExporter=Yes
PrometheusHost=0.0.0.0
PrometheusPort=8081
PrometheusInterval=30
```

**Endpoint**: http://slurmctld:8081/metrics

### Prometheus

Time-series database that scrapes and stores metrics.

**Configuration**: `config/prometheus/prometheus.yml`

**Scrape Targets**:
- `slurm` job: slurmctld:8081 (Slurm metrics)
- `pushgateway` job: pushgateway:9091 (application metrics)

**Retention**: Default 15 days (configurable)

### Pushgateway

Allows batch jobs and short-lived processes to push metrics to Prometheus.

**Use Cases**:
- Job completion metrics
- Application usage statistics
- Custom business metrics

**Endpoint**: http://pushgateway:9091

### Grafana

Visualization and dashboarding platform.

**Pre-configured**:
- Prometheus datasource (automatic)
- Two dashboards (automatic):
  - Slurm Cluster Overview
  - Application Metrics

**Credentials**: admin/admin (default)

## Metrics Available

### Slurm Cluster Metrics

Exposed by PrometheusExporter (prefix: `slurm_*`):

#### Node Metrics
- `slurm_node_info` - Node information (hostname, state, partition)
- `slurm_node_cpus_total` - Total CPUs per node
- `slurm_node_cpus_idle` - Idle CPUs per node
- `slurm_node_cpus_allocated` - Allocated CPUs per node
- `slurm_node_memory_total` - Total memory per node
- `slurm_node_memory_idle` - Available memory per node

#### Job Metrics
- `slurm_jobs_total` - Total jobs in all states
- `slurm_jobs_running` - Currently running jobs
- `slurm_jobs_pending` - Jobs waiting in queue
- `slurm_jobs_completed_total` - Completed jobs (counter)
- `slurm_jobs_failed_total` - Failed jobs (counter)
- `slurm_jobs_cancelled_total` - Cancelled jobs (counter)

#### Partition Metrics
- `slurm_partition_info` - Partition configuration
- `slurm_partition_nodes_total` - Nodes in partition
- `slurm_partition_nodes_idle` - Idle nodes in partition
- `slurm_partition_jobs_running` - Running jobs per partition

#### Scheduler Metrics
- `slurm_scheduler_info` - Scheduler status and configuration
- `slurm_scheduler_backfill_mean_cycle` - Backfill cycle time

### Application Metrics

Custom metrics pushed by applications (prefix: `app_*`):

- `app_job_executions_total{app_name, username, partition}` - Number of executions
- `app_job_duration_seconds{app_name, username, partition}` - Job duration
- `app_data_processed_mb{app_name, username, partition}` - Data processed in MB
- `app_tasks_completed_total{app_name, username, partition}` - Tasks completed

Labels allow filtering and aggregation by:
- **app_name**: Application name (e.g., "blast", "gromacs", "tensorflow")
- **username**: User who ran the job
- **partition**: Slurm partition used

## Query Examples

### PromQL Basics

Access Prometheus web UI at http://localhost:9090 and try these queries:

#### Cluster Status

```promql
# Total nodes in cluster
count(slurm_node_info)

# Nodes by state
count by (state) (slurm_node_info)

# CPU utilization percentage
100 * (1 - (sum(slurm_node_cpus_idle) / sum(slurm_node_cpus_total)))

# Available memory across cluster
sum(slurm_node_memory_idle)
```

#### Job Statistics

```promql
# Currently running jobs
slurm_jobs_running

# Job completion rate (jobs/sec over last 5 minutes)
rate(slurm_jobs_completed_total[5m])

# Jobs by partition
sum by (partition) (slurm_partition_jobs_running)

# Average queue wait time (if metric available)
avg(slurm_job_wait_time_seconds)
```

#### Application Analytics

```promql
# Most used applications
topk(5, sum by (app_name) (app_job_executions_total))

# Total executions per user
sum by (username) (app_job_executions_total)

# Average job duration by application
avg by (app_name) (app_job_duration_seconds)

# Data processing rate (MB/sec)
app_data_processed_mb / app_job_duration_seconds

# Application usage heatmap
sum by (app_name, username) (app_job_executions_total)
```

#### Time-Series Analysis

```promql
# CPU utilization over time
100 * (1 - (sum(slurm_node_cpus_idle) / sum(slurm_node_cpus_total)))

# Job throughput (jobs completed per hour)
increase(slurm_jobs_completed_total[1h])

# Trend in application usage (rate over 6 hours)
rate(app_job_executions_total[6h])
```

### Using the Query Scripts

Run pre-built query examples:

```bash
# Slurm cluster metrics
./examples/prometheus/query_slurm_metrics.sh

# Application metrics
./examples/prometheus/query_app_metrics.sh
```

## Application Instrumentation

### Python Example

Use the `prometheus_client` library to push metrics:

```python
#!/usr/bin/env python3
from prometheus_client import CollectorRegistry, Counter, Gauge, push_to_gateway
import os

# Create registry
registry = CollectorRegistry()

# Define metrics
job_counter = Counter(
    'app_job_executions_total',
    'Total job executions',
    ['app_name', 'username'],
    registry=registry
)

duration_gauge = Gauge(
    'app_job_duration_seconds',
    'Job duration',
    ['app_name', 'username'],
    registry=registry
)

# Get context
app_name = 'my_app'
username = os.environ.get('USER', 'unknown')

# Record metrics
job_counter.labels(app_name=app_name, username=username).inc()
duration_gauge.labels(app_name=app_name, username=username).set(42.5)

# Push to Pushgateway
push_to_gateway(
    'pushgateway:9091',
    job=f'{app_name}_{username}',
    registry=registry
)
```

### Slurm Batch Script Example

```bash
#!/bin/bash
#SBATCH --job-name=my_analysis
#SBATCH --output=/data/my_analysis_%j.out

# Install prometheus_client
python3 -m pip install --user prometheus-client

# Run your application with metrics
python3 my_app_with_metrics.py

# Application automatically pushes metrics to Pushgateway
```

### Demo Application

A complete demo is provided:

```bash
# View demo source
cat examples/prometheus/app_metrics_demo.py

# Submit demo job
sbatch examples/jobs/prometheus_demo.sh

# Check job output
tail -f /data/prometheus_demo_*.out
```

### Best Practices

1. **Unique job labels**: Use `{app_name}_{username}` as the job label
2. **Consistent naming**: Use lowercase with underscores for metric names
3. **Meaningful labels**: Include app_name, username, partition for filtering
4. **Push on completion**: Push metrics at the end of your job
5. **Error handling**: Wrap push_to_gateway in try/except

## Grafana Dashboards

### Pre-configured Dashboards

Two dashboards are automatically loaded:

#### 1. Slurm Cluster Overview

Navigate to: Dashboards → Slurm Cluster Overview

**Panels**:
- Total nodes, CPUs, utilization (stats)
- Running and pending jobs (stats)
- Job count over time (time series)
- CPU utilization over time (time series)
- Node information (table)
- Nodes by state (pie chart)

**Variables**: None (shows full cluster)

**Refresh**: 10 seconds

#### 2. Application Metrics

Navigate to: Dashboards → Application Metrics

**Panels**:
- Total executions, unique apps, data processed, tasks (stats)
- Job executions by application (pie chart)
- Executions by application and user (stacked bar chart)
- Application statistics table (executions, duration, data, tasks)
- Job duration by application (time series)
- Data processed over time (stacked area chart)

**Variables**: None (shows all applications)

**Refresh**: 10 seconds

### Creating Custom Dashboards

1. Log in to Grafana: http://localhost:3000 (admin/admin)
2. Click **+** → **Dashboard**
3. Click **Add visualization**
4. Select **Prometheus** datasource
5. Enter PromQL query
6. Configure visualization type (graph, stat, table, etc.)
7. Save dashboard

### Sharing Dashboards

Export dashboard JSON:
1. Dashboard settings (⚙️) → **JSON Model**
2. Copy JSON
3. Save to `config/grafana/dashboards/my_dashboard.json`
4. Restart Grafana: `docker compose restart grafana`

## Troubleshooting

### Prometheus Not Scraping Slurm Metrics

**Check PrometheusExporter**:
```bash
# Verify config
docker exec slurmctld grep Prometheus /etc/slurm/slurm.conf

# Test endpoint directly
docker exec slurmctld curl http://localhost:8081/metrics

# Check for slurm_ metrics
docker exec slurmctld curl -s http://localhost:8081/metrics | grep "^slurm_"
```

**Check Prometheus targets**:
- Open http://localhost:9090/targets
- Verify `slurm` target is UP
- Check error messages if DOWN

**Common issues**:
- PrometheusExporter not enabled in slurm.conf
- Port 8081 not exposed in docker-compose.yml
- slurmctld not restarted after config change

**Fix**:
```bash
# Restart slurmctld
docker compose restart slurmctld

# Wait for health check
sleep 10

# Verify endpoint
curl http://localhost:8081/metrics
```

### Application Metrics Not Appearing

**Check Pushgateway**:
```bash
# View raw metrics
curl http://localhost:9091/metrics | grep app_

# Check Pushgateway UI
# Open http://localhost:9091
```

**Check job logs**:
```bash
# View job output
docker exec slurmctld tail -f /data/prometheus_demo_*.out

# Look for "Metrics pushed successfully" message
```

**Common issues**:
- prometheus_client not installed
- Wrong Pushgateway address
- Network connectivity issues
- Job failed before pushing metrics

**Fix**:
```bash
# Test from slurmctld
docker exec slurmctld python3 -c "from prometheus_client import push_to_gateway; print('OK')"

# Test network
docker exec slurmctld curl http://pushgateway:9091/-/healthy
```

### Grafana Dashboard Empty

**Check Prometheus datasource**:
1. Grafana → Configuration → Data sources
2. Click **Prometheus**
3. Scroll down → **Save & test**
4. Should see "Data source is working"

**Check dashboard queries**:
1. Open dashboard
2. Panel menu → **Edit**
3. Check query syntax
4. View query inspector for errors

**Check time range**:
- Ensure dashboard time range includes data
- Default is "Last 15 minutes"
- Adjust if no recent data

**Common issues**:
- No data in Prometheus yet (wait for scrape interval)
- Time range outside of data availability
- PromQL query syntax error

**Fix**:
```bash
# Generate test data
docker exec slurmctld sbatch /data/examples/jobs/prometheus_demo.sh

# Wait for job completion and scraping
sleep 30

# Query Prometheus directly
curl -G --data-urlencode "query=app_job_executions_total" \
  http://localhost:9090/api/v1/query | jq .
```

### High Memory Usage

Prometheus stores metrics in memory. For long-running clusters:

**Configure retention**:

Edit `config/prometheus/prometheus.yml`:
```yaml
global:
  # Reduce scrape interval
  scrape_interval: 60s  # Instead of 30s
```

Or add storage limits in `docker-compose.yml`:
```yaml
prometheus:
  command:
    - '--storage.tsdb.retention.time=7d'  # Keep 7 days
    - '--storage.tsdb.retention.size=10GB' # Max 10GB
```

### Services Not Starting

```bash
# Check logs
make logs-prometheus
make logs-pushgateway
make logs-grafana

# Check docker compose profile
docker compose --profile prometheus ps

# Verify .env configuration
grep PROMETHEUS_ENABLE .env

# Restart services
docker compose --profile prometheus down
docker compose --profile prometheus up -d
```

### Test Suite Failures

```bash
# Run test suite with verbose output
./test_prometheus.sh

# Check individual service health
docker exec prometheus wget -qO- http://localhost:9090/-/healthy
docker exec pushgateway wget -qO- http://localhost:9091/-/healthy
docker exec grafana wget -qO- http://localhost:3000/api/health

# Full cluster test
make test
```

## Additional Resources

### Documentation

- [Prometheus Documentation](https://prometheus.io/docs/)
- [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Slurm PrometheusExporter](https://slurm.schedmd.com/prometheus.html)
- [prometheus_client Python](https://github.com/prometheus/client_python)

### Query Recipes

See `examples/prometheus/` directory for:
- `query_slurm_metrics.sh` - Cluster monitoring queries
- `query_app_metrics.sh` - Application usage queries
- `app_metrics_demo.py` - Python instrumentation example

### Exporting Data

**Export Prometheus data**:
```bash
# Query API
curl -G --data-urlencode "query=slurm_jobs_total" \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)" \
  --data-urlencode "end=$(date +%s)" \
  --data-urlencode "step=60" \
  http://localhost:9090/api/v1/query_range | jq .
```

**Export Grafana dashboard**:
- Dashboard → Share → Export → Save to file

### Advanced Configuration

**Custom metrics**:
- Add your own metrics following the prometheus_client examples
- Use appropriate metric types (Counter, Gauge, Histogram, Summary)
- Document your metrics in your application's README

**Alerting**:
- Configure AlertManager (not included in this demo)
- Define alert rules in Prometheus
- Send notifications to Slack, email, PagerDuty, etc.

**Long-term storage**:
- Configure remote write to external storage
- Options: InfluxDB, TimescaleDB, Thanos, Cortex
- Useful for retention beyond 15 days

## Support

For issues or questions:
1. Check this documentation
2. Run test suite: `make test-prometheus`
3. Check logs: `make logs-prometheus`
4. Review [Prometheus troubleshooting](https://prometheus.io/docs/prometheus/latest/troubleshooting/)
5. Check Slurm logs: `make logs-slurmctld`
