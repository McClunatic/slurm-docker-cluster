#!/usr/bin/env python3
"""
Example: Submit a Slurm batch job that collects and pushes custom metrics to Prometheus Pushgateway.

This script demonstrates:
  1. Creating a Python virtual environment in the job
  2. Installing prometheus_client library
  3. Collecting custom metrics during job execution
  4. Pushing metrics to the Prometheus Pushgateway before job completion

The job runs for 10 seconds, simulates some work, tracks execution time and
memory usage, and then pushes those metrics to the pushgateway where Prometheus
can scrape them.

Usage:
    python3 examples/submit_job_with_metrics.py

Monitoring the metrics:
    1. Open Grafana: http://localhost:3000 (admin/admin)
    2. Go to Explore tab
    3. Query: {job="<job_id>"}
    4. You should see custom_job_* metrics from this job
"""

import os
import subprocess
import tempfile
import sys

def create_job_script():
    """Create the batch job script with metric collection."""
    return '''#!/bin/bash
#SBATCH --job-name=metrics-demo
#SBATCH --time=1:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=256M
#SBATCH --output=%x-%j.log

set -e

echo "Job started at $(date)"
echo "Job ID: $SLURM_JOB_ID"
echo "Hostname: $(hostname)"
echo ""

# Setup Python virtual environment
echo "Creating Python virtual environment..."
python3 -m venv /tmp/job_venv
source /tmp/job_venv/bin/activate

# Install prometheus_client
echo "Installing prometheus-client library..."
pip install -q prometheus-client

# Run Python job with metrics collection
echo "Running job with metrics collection..."
python3 << 'EOF'
import time
import os
import psutil
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

# Initialize metrics registry
registry = CollectorRegistry()

# Define custom metrics
job_duration = Gauge(
    'custom_job_duration_seconds',
    'Total job execution time in seconds',
    registry=registry
)
job_memory_peak = Gauge(
    'custom_job_memory_peak_mb',
    'Peak memory usage in MB',
    registry=registry
)
job_cpu_time = Gauge(
    'custom_job_cpu_time_seconds',
    'Total CPU time used by job',
    registry=registry
)
job_status = Gauge(
    'custom_job_status',
    'Job completion status (1=success, 0=failed)',
    registry=registry
)

start_time = time.time()
process = psutil.Process()
initial_cpu_time = process.cpu_times().user + process.cpu_times().system

try:
    # Simulate work for 10 seconds
    print("Doing work...")
    for i in range(10):
        print(f"  Iteration {i+1}/10 - {i*10}% complete")
        time.sleep(1)
        # Do some CPU work
        _ = sum(range(1000000))
    
    # Record metrics
    end_time = time.time()
    final_cpu_time = process.cpu_times().user + process.cpu_times().system
    
    job_duration.set(end_time - start_time)
    job_memory_peak.set(process.memory_info().rss / (1024 * 1024))  # Convert to MB
    job_cpu_time.set(final_cpu_time - initial_cpu_time)
    job_status.set(1)  # Success
    
    print(f"\nJob completed successfully!")
    print(f"  Execution time: {end_time - start_time:.2f}s")
    print(f"  Memory peak: {process.memory_info().rss / (1024 * 1024):.2f} MB")
    print(f"  CPU time: {final_cpu_time - initial_cpu_time:.2f}s")
    
except Exception as e:
    job_status.set(0)  # Failure
    print(f"Error: {e}", file=__import__('sys').stderr)
    raise

# Push metrics to Pushgateway
# The pushgateway address is typically http://pushgateway:9091
# We use the job ID as the job label so metrics are grouped by job
pushgateway_address = os.environ.get('PUSHGATEWAY_ADDRESS', 'pushgateway:9091')
job_id = os.environ.get('SLURM_JOB_ID', 'unknown')

print(f"\nPushing metrics to pushgateway ({pushgateway_address})...")
try:
    push_to_gateway(
        pushgateway_address,
        job=f'slurm_job_{job_id}',
        registry=registry
    )
    print("✓ Metrics successfully pushed!")
except Exception as e:
    print(f"Warning: Failed to push metrics: {e}")
    # Don't fail the job if pushgateway is unavailable

EOF

# Cleanup
deactivate
rm -rf /tmp/job_venv

echo ""
echo "Job completed at $(date)"
'''

def submit_job():
    """Submit the job to Slurm."""
    script_path = None
    try:
        # Create temporary file for job script
        with tempfile.NamedTemporaryFile(mode='w', suffix='.sh', delete=False) as f:
            f.write(create_job_script())
            script_path = f.name
        
        # Make script executable
        os.chmod(script_path, 0o755)
        
        # Submit job
        print("Submitting Slurm job with metrics collection...")
        result = subprocess.run(
            ['sbatch', script_path],
            capture_output=True,
            text=True,
            check=True
        )
        
        # Extract job ID from output
        output = result.stdout.strip()
        job_id = output.split()[-1]
        
        print(f"✓ Job submitted successfully!")
        print(f"  Job ID: {job_id}")
        print(f"  Status: 'squeue' to check status")
        print(f"  Logs: {job_id}-job-*.log")
        print("")
        print("Metrics will be available in Grafana after job completes:")
        print("  1. Open http://localhost:3000 (admin/admin)")
        print("  2. Go to Explore tab")
        print(f"  3. Query: {{job=~\"slurm_job_{job_id}.*\"}}")
        print("     or: custom_job_*")
        
    except subprocess.CalledProcessError as e:
        print(f"✗ Error submitting job:")
        print(f"  {e.stderr}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("✗ Error: sbatch command not found", file=sys.stderr)
        print("  Are you running this inside the Slurm cluster?", file=sys.stderr)
        sys.exit(1)
    finally:
        # Clean up temporary script
        if script_path:
            try:
                os.unlink(script_path)
            except:
                pass

if __name__ == '__main__':
    # Check if we're in the Slurm environment
    if not os.path.exists('/etc/slurm'):
        print("Warning: /etc/slurm not found", file=sys.stderr)
        print("  This script should be run from within the Slurm cluster container.", file=sys.stderr)
        print("  Usage: docker exec slurmctld python3 examples/submit_job_with_metrics.py")
        sys.exit(1)
    
    submit_job()
