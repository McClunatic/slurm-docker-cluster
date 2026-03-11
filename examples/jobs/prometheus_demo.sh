#!/bin/bash
#SBATCH --job-name=prometheus_demo
#SBATCH --output=/data/prometheus_demo_%j.out
#SBATCH --ntasks=1
#SBATCH --time=00:05:00
#SBATCH --partition=cpu

# Prometheus Application Metrics Demo Job
# This job demonstrates how to push custom application metrics to Prometheus Pushgateway
# 
# The demo simulates a scientific application that:
# - Processes data
# - Completes tasks
# - Reports metrics to Prometheus for monitoring and analysis

echo "========================================="
echo "Prometheus Application Metrics Demo"
echo "========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Job Name: $SLURM_JOB_NAME"
echo "Running on: $(hostname)"
echo "User: $USER"
echo "Partition: $SLURM_JOB_PARTITION"
echo "Started at: $(date)"
echo ""

# Install prometheus_client if not already available
echo "Installing Python dependencies..."
python3 -m pip install -q --user prometheus-client || {
    echo "Error: Failed to install prometheus-client"
    exit 1
}
echo "✓ Dependencies installed"
echo ""

# Make the demo script executable
chmod +x /data/examples/prometheus/app_metrics_demo.py

# Run the demo with different application names to simulate
# multiple applications being monitored
APP_NAMES=("data_processor" "sequence_aligner" "model_trainer")
APP_NAME=${APP_NAMES[$((SLURM_JOB_ID % 3))]}

echo "Running application: $APP_NAME"
echo ""

# Execute the demo application
/data/examples/prometheus/app_metrics_demo.py \
    --app-name "$APP_NAME" \
    --pushgateway pushgateway:9091 \
    --duration 10

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Job completed successfully"
else
    echo "✗ Job failed with exit code $EXIT_CODE"
fi
echo "Finished at: $(date)"
echo "========================================="

exit $EXIT_CODE
