#!/usr/bin/env python3
"""
Prometheus Application Metrics Demo

This script demonstrates how user applications can push custom metrics
to Prometheus Pushgateway for monitoring application usage patterns.

Metrics tracked:
- Application execution count (counter)
- Job duration (gauge)
- Custom business metrics (gauge)
"""

import argparse
import os
import random
import time
from prometheus_client import CollectorRegistry, Counter, Gauge, push_to_gateway


def main():
    parser = argparse.ArgumentParser(
        description='Demo application that pushes metrics to Prometheus Pushgateway'
    )
    parser.add_argument(
        '--app-name',
        default='demo_app',
        help='Application name (default: demo_app)'
    )
    parser.add_argument(
        '--pushgateway',
        default='pushgateway:9091',
        help='Pushgateway address (default: pushgateway:9091)'
    )
    parser.add_argument(
        '--duration',
        type=int,
        default=5,
        help='Simulated job duration in seconds (default: 5)'
    )
    args = parser.parse_args()

    # Get user and job information from Slurm environment variables
    username = os.environ.get('USER', 'unknown')
    job_id = os.environ.get('SLURM_JOB_ID', 'local')
    job_name = os.environ.get('SLURM_JOB_NAME', 'interactive')
    partition = os.environ.get('SLURM_JOB_PARTITION', 'unknown')
    
    print(f"Application Metrics Demo")
    print(f"========================")
    print(f"Application: {args.app_name}")
    print(f"User: {username}")
    print(f"Job ID: {job_id}")
    print(f"Job Name: {job_name}")
    print(f"Partition: {partition}")
    print(f"Pushgateway: {args.pushgateway}")
    print()

    # Create a custom registry for this job
    registry = CollectorRegistry()

    # Define metrics
    job_executions = Counter(
        'app_job_executions_total',
        'Total number of job executions',
        ['app_name', 'username', 'partition'],
        registry=registry
    )

    job_duration = Gauge(
        'app_job_duration_seconds',
        'Duration of job execution in seconds',
        ['app_name', 'username', 'partition'],
        registry=registry
    )

    data_processed = Gauge(
        'app_data_processed_mb',
        'Amount of data processed in megabytes',
        ['app_name', 'username', 'partition'],
        registry=registry
    )

    tasks_completed = Gauge(
        'app_tasks_completed_total',
        'Number of tasks completed in this job',
        ['app_name', 'username', 'partition'],
        registry=registry
    )

    # Simulate application work
    print("Starting simulated work...")
    start_time = time.time()
    
    # Simulate processing with progress updates
    simulated_data_mb = 0
    simulated_tasks = 0
    
    for i in range(args.duration):
        time.sleep(1)
        # Simulate processing random amounts of data
        chunk_mb = random.uniform(10, 100)
        simulated_data_mb += chunk_mb
        simulated_tasks += random.randint(1, 10)
        print(f"  Progress: {i+1}/{args.duration}s - Processed: {simulated_data_mb:.1f} MB, Tasks: {simulated_tasks}")

    duration_seconds = time.time() - start_time

    print()
    print("Work completed! Recording metrics...")

    # Record metrics with labels
    labels = {
        'app_name': args.app_name,
        'username': username,
        'partition': partition
    }

    job_executions.labels(**labels).inc()
    job_duration.labels(**labels).set(duration_seconds)
    data_processed.labels(**labels).set(simulated_data_mb)
    tasks_completed.labels(**labels).set(simulated_tasks)

    # Push metrics to Pushgateway
    # Use job and instance labels to identify this specific job
    job_label = f"{args.app_name}_{username}"
    instance_label = f"job_{job_id}"

    try:
        push_to_gateway(
            args.pushgateway,
            job=job_label,
            registry=registry,
            grouping_key={'instance': instance_label}
        )
        print(f"✓ Metrics pushed to Pushgateway successfully")
        print(f"  Job label: {job_label}")
        print(f"  Instance: {instance_label}")
        print()
        print("Metrics summary:")
        print(f"  - Executions: +1")
        print(f"  - Duration: {duration_seconds:.2f} seconds")
        print(f"  - Data processed: {simulated_data_mb:.1f} MB")
        print(f"  - Tasks completed: {simulated_tasks}")
        print()
        print("View metrics at: http://localhost:9091/metrics")
        print("Query in Prometheus: http://localhost:9090/graph")
        print("Visualize in Grafana: http://localhost:3000/")
    except Exception as e:
        print(f"✗ Error pushing metrics: {e}")
        return 1

    return 0


if __name__ == '__main__':
    exit(main())
