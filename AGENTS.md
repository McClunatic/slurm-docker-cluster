# AGENTS.md - Slurm Docker Cluster

## Project Overview

Multi-container Slurm cluster deployed with Docker Compose. The codebase consists of:
- Shell scripts (bash) for testing and automation
- Docker configuration (Dockerfile, docker-compose.yml)
- Makefile for build/cluster management
- Slurm configuration files

---

## Build, Lint, and Test Commands

### Quick Start
```bash
cp .env.example .env
make build
make up
make status
```

### Running Tests

**Run full test suite:**
```bash
make test
```

This executes `./test_cluster.sh` (20+ tests): container health, MUNGE, MySQL/slurmdbd/slurmctld connectivity, compute node registration, job submission/execution, multi-node jobs, dynamic scaling, REST API, JWT auth.

**Run specific test scripts:**
```bash
make test-users         # Multi-user tests
make test-monitoring    # Monitoring profile tests
make test-gpu          # GPU profile tests
make quick-test        # Submit simple job
```

### Single Test Execution

1. Edit `test_cluster.sh` and comment out unwanted tests in `main()`
2. Or run manually:
```bash
docker compose ps
docker exec slurmctld bash -c "munge -n | unmunge"
docker exec slurmctld scontrol ping
docker exec slurmctld sbatch --wrap='hostname'
```

### Build Commands
```bash
make build              # Build Docker images
make build-no-cache    # Build without cache
make rebuild           # Clean, build, start
make build-all         # Build all supported Slurm versions
```

### Cluster Management
```bash
make up               # Start containers
make down              # Stop containers
make clean             # Remove containers/volumes
make status            # Show cluster status
make shell             # Open shell in slurmctld
make logs              # View container logs
make scale-cpu-workers N=3
make scale-gpu-workers N=2
make version           # Show current Slurm version
make set-version VER=25.05.6
```

---

## Code Style Guidelines

### Shell Scripts (bash)

**File Header:**
- Start with `#!/bin/bash`
- Use `set -e` to exit on error

**Variables:**
- UPPERCASE for env vars, lowercase for local
- Always quote: `"$VAR"` not `$VAR`
- Meaningful names: `SLURM_VERSION`, `NODE_COUNT`

**Functions:**
- Use `local` for function-local variables
- Prefer `local var=$(command)` over backticks
- Handle empty: `[ -z "$VAR" ]`

**Error Handling:**
```bash
set -e

if ! command -v docker &> /dev/null; then
    echo "Error: docker is required"
    exit 1
fi

if [ -z "$REQUIRED_PARAM" ]; then
    echo "Error: REQUIRED_PARAM is required"
    exit 1
fi
```

**Tests/Conditionals:**
- Use `[[ ]]` over `[ ]` in bash
- Use `-z` for empty, `-n` for non-empty

### Docker Configuration

**Dockerfile:**
- Use specific version tags, not `latest`
- Use multi-stage builds when possible
- Combine RUN commands, clean in same layer

**docker-compose.yml:**
- Use healthchecks for dependencies
- Use depends_on with conditionals

### Makefile

- Document targets with `##` comments
- Use `.PHONY` for non-file targets
- Use `$(VAR)` syntax

### Git/Version Control

- Use conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`
- Tests run on push/PR to main (see `.github/workflows/test.yml`)

---

## Supported Slurm Versions

- **25.11.x** (latest)
- **25.05.x**

Set in `.env`: `SLURM_VERSION=25.11.2`

---

## Common Tasks

### Adding a New Test
1. Add test function in `test_cluster.sh`
2. Use print functions: `print_test`, `print_pass`, `print_fail`, `print_info`
3. Register in `main()` function
4. Return 0 for pass, 1 for fail

### Updating Slurm Version
1. Update `.env.example`
2. Add to `SUPPORTED_VERSIONS` in Makefile
3. Test: `make test-version VER=<new-version>`

### Modifying Container Startup
Edit `docker-entrypoint.sh` - detects service type from `$1`.

---

## Useful Commands
```bash
make help
make status
make logs
docker exec slurmctld <command>
```
