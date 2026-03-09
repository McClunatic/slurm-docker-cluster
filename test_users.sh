#!/bin/bash
set -e

# Detect if running in CI
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

# Check if USERS is configured
check_users_configured() {
    print_test "Checking if USERS environment variable is configured..."
    
    USERS_VAR=$(docker exec slurmctld bash -c 'echo $USERS' 2>/dev/null || echo "")
    
    if [ -z "$USERS_VAR" ]; then
        print_fail "USERS environment variable is not set"
        echo ""
        echo "To enable multi-user testing, add USERS to your .env file:"
        echo "  echo 'USERS=alice bob carol' >> .env"
        echo "  docker compose restart"
        echo ""
        exit 1
    else
        print_pass "USERS is configured: $USERS_VAR"
    fi
}

# Test user creation in slurmctld
test_users_in_slurmctld() {
    print_test "Verifying users exist in slurmctld container..."
    
    USERS_VAR=$(docker exec slurmctld bash -c 'echo $USERS')
    # Parse users (handle both comma and space delimiters)
    USERS_LIST=$(echo "$USERS_VAR" | tr ',' ' ' | tr -s ' ')
    
    ALL_EXIST=true
    for user in $USERS_LIST; do
        if docker exec slurmctld id "$user" >/dev/null 2>&1; then
            UID_=$(docker exec slurmctld id -u "$user")
            print_info "  ✓ User '$user' exists with UID $UID_"
        else
            print_fail "  ✗ User '$user' does not exist"
            ALL_EXIST=false
        fi
    done
    
    if [ "$ALL_EXIST" = true ]; then
        print_pass "All users exist in slurmctld"
    else
        print_fail "Some users are missing in slurmctld"
        return 1
    fi
}

# Test user creation in cpu workers
test_users_in_workers() {
    print_test "Verifying users exist in cpu-worker containers..."
    
    USERS_VAR=$(docker exec slurmctld bash -c 'echo $USERS')
    USERS_LIST=$(echo "$USERS_VAR" | tr ',' ' ' | tr -s ' ')
    
    # Get list of cpu-worker containers
    WORKERS=$(docker compose ps cpu-worker --format '{{.Names}}' 2>/dev/null)
    
    if [ -z "$WORKERS" ]; then
        print_fail "No cpu-worker containers found"
        return 1
    fi
    
    ALL_EXIST=true
    for worker in $WORKERS; do
        print_info "  Checking $worker..."
        for user in $USERS_LIST; do
            if docker exec "$worker" id "$user" >/dev/null 2>&1; then
                UID_=$(docker exec "$worker" id -u "$user")
                print_info "    ✓ User '$user' exists with UID $UID_"
            else
                print_fail "    ✗ User '$user' does not exist"
                ALL_EXIST=false
            fi
        done
    done
    
    if [ "$ALL_EXIST" = true ]; then
        print_pass "All users exist in all worker containers"
    else
        print_fail "Some users are missing in worker containers"
        return 1
    fi
}

# Test UID consistency across containers
test_uid_consistency() {
    print_test "Verifying UID consistency across containers..."
    
    USERS_VAR=$(docker exec slurmctld bash -c 'echo $USERS')
    USERS_LIST=$(echo "$USERS_VAR" | tr ',' ' ' | tr -s ' ')
    
    # Get all container names
    CONTAINERS="slurmctld"
    WORKERS=$(docker compose ps cpu-worker --format '{{.Names}}' 2>/dev/null)
    CONTAINERS="$CONTAINERS $WORKERS"
    
    ALL_CONSISTENT=true
    for user in $USERS_LIST; do
        print_info "  Checking UID consistency for '$user'..."
        FIRST_UID=""
        
        for container in $CONTAINERS; do
            UID_=$(docker exec "$container" id -u "$user" 2>/dev/null || echo "MISSING")
            
            if [ "$UID_" = "MISSING" ]; then
                print_fail "    ✗ User '$user' missing in $container"
                ALL_CONSISTENT=false
                continue
            fi
            
            if [ -z "$FIRST_UID" ]; then
                FIRST_UID=$UID_
            fi
            
            if [ "$UID_" != "$FIRST_UID" ]; then
                print_fail "    ✗ UID mismatch in $container: $UID_ vs expected $FIRST_UID"
                ALL_CONSISTENT=false
            else
                print_info "    ✓ $container: UID $UID"
            fi
        done
    done
    
    if [ "$ALL_CONSISTENT" = true ]; then
        print_pass "UIDs are consistent across all containers"
    else
        print_fail "UID inconsistencies detected"
        return 1
    fi
}

# Test command execution as user
test_command_execution() {
    print_test "Testing command execution as user..."
    
    USERS_VAR=$(docker exec slurmctld bash -c 'echo $USERS')
    # Get first user
    FIRST_USER=$(echo "$USERS_VAR" | tr ',' ' ' | awk '{print $1}')
    
    if [ -z "$FIRST_USER" ]; then
        print_fail "No users found to test"
        return 1
    fi
    
    # Test whoami
    WHOAMI_OUTPUT=$(docker exec -u "$FIRST_USER" slurmctld whoami 2>/dev/null || echo "FAILED")
    
    if [ "$WHOAMI_OUTPUT" = "$FIRST_USER" ]; then
        print_pass "Command execution works (whoami returned: $WHOAMI_OUTPUT)"
    else
        print_fail "Command execution failed (expected: $FIRST_USER, got: $WHOAMI_OUTPUT)"
        return 1
    fi
}

# Test /data directory access
test_data_access() {
    print_test "Testing /data directory access for users..."
    
    USERS_VAR=$(docker exec slurmctld bash -c 'echo $USERS')
    FIRST_USER=$(echo "$USERS_VAR" | tr ',' ' ' | awk '{print $1}')
    
    if [ -z "$FIRST_USER" ]; then
        print_fail "No users found to test"
        return 1
    fi
    
    # Test creating and reading a file in /data
    TEST_FILE="/data/test_user_${FIRST_USER}_$$"
    
    if docker exec -u "$FIRST_USER" slurmctld bash -c "echo 'test' > $TEST_FILE && cat $TEST_FILE" >/dev/null 2>&1; then
        print_pass "/data directory is accessible for users"
        # Clean up
        docker exec slurmctld rm -f "$TEST_FILE" 2>/dev/null || true
    else
        print_fail "/data directory is not accessible for users"
        return 1
    fi
}

# Test job submission as user
test_job_submission() {
    print_test "Testing Slurm job submission as user..."
    
    USERS_VAR=$(docker exec slurmctld bash -c 'echo $USERS')
    FIRST_USER=$(echo "$USERS_VAR" | tr ',' ' ' | awk '{print $1}')
    
    if [ -z "$FIRST_USER" ]; then
        print_fail "No users found to test"
        return 1
    fi
    
    # Submit a simple job
    JOB_OUTPUT=$(docker exec -u "$FIRST_USER" slurmctld bash -c "srun --output=/dev/null hostname" 2>&1 || echo "FAILED")
    
    if [ "$JOB_OUTPUT" != "FAILED" ] && [ -z "$(echo "$JOB_OUTPUT" | grep -i error)" ]; then
        print_pass "Job submission works for user '$FIRST_USER'"
    else
        print_fail "Job submission failed for user '$FIRST_USER': $JOB_OUTPUT"
        return 1
    fi
    
    print_test "Testing Slurm job accounting as user..."

    # Check job accounting
    SACCT_OUTPUT=$(docker exec -u "$FIRST_USER" slurmctld sacct -n --format=User 2>/dev/null | grep -Ev '^\s*$'  | tail -1 | xargs)
    
    if [ "$SACCT_OUTPUT" = "$FIRST_USER" ]; then
        print_pass "Job accounting shows correct user: $SACCT_OUTPUT"
    else
        print_fail "Job accounting shows wrong user (expected: $FIRST_USER, got: $SACCT_OUTPUT)"
        return 1
    fi
}

# Test alphabetical sorting of users
test_alphabetical_ordering() {
    print_test "Verifying users are sorted alphabetically for UID assignment..."
    
    USERS_VAR=$(docker exec slurmctld bash -c 'echo $USERS')
    USERS_LIST=$(echo "$USERS_VAR" | tr ',' ' ' | tr -s ' ')
    
    # Sort users alphabetically
    SORTED_USERS=$(echo "$USERS_LIST" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    
    ALL_CORRECT=true
    EXPECTED_UID=1000
    
    for user in $SORTED_USERS; do
        ACTUAL_UID=$(docker exec slurmctld id -u "$user" 2>/dev/null || echo "MISSING")
        
        if [ "$ACTUAL_UID" = "$EXPECTED_UID" ]; then
            print_info "  ✓ User '$user' has correct UID $ACTUAL_UID"
        else
            print_fail "  ✗ User '$user' has UID $ACTUAL_UID, expected $EXPECTED_UID"
            ALL_CORRECT=false
        fi
        
        EXPECTED_UID=$((EXPECTED_UID + 1))
    done
    
    if [ "$ALL_CORRECT" = true ]; then
        print_pass "Users are correctly sorted with sequential UIDs"
    else
        print_fail "User UID assignment does not follow alphabetical order"
        return 1
    fi
}

# Main test execution
main() {
    print_header "Slurm Multi-User Test Suite"
    echo ""
    
    # Check if users are configured
    check_users_configured
    echo ""
    
    # Run tests
    test_users_in_slurmctld || true
    echo ""
    
    test_users_in_workers || true
    echo ""
    
    test_uid_consistency || true
    echo ""
    
    test_alphabetical_ordering || true
    echo ""
    
    test_command_execution || true
    echo ""
    
    test_data_access || true
    echo ""
    
    test_job_submission || true
    echo ""
    
    # Print summary
    print_header "Test Summary"
    echo -e "Tests Run:    ${TESTS_RUN}"
    echo -e "Tests Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Tests Failed: ${RED}${TESTS_FAILED}${NC}"
    echo ""
    
    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

# Run main function
main
