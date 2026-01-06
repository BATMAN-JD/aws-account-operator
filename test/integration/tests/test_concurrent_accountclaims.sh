#!/usr/bin/env bash

# Test Description:
#  This test validates that the operator correctly handles concurrent AccountClaims competing
#  for accounts from the same pool. It tests the race condition handling and ensures no
#  duplicate account assignments occur.
#
#  The test:
#  1. Creates a pool with 2 accounts
#  2. Creates 5 AccountClaims simultaneously (all at once)
#  3. Verifies exactly 2 claims get accounts (become Ready)
#  4. Verifies remaining 3 claims stay Pending (pool exhausted)
#  5. Verifies no duplicate account assignments
#  6. Verifies all assigned accounts are from the correct pool
#
#  This validates:
#  - Race condition handling in account selection
#  - Kubernetes optimistic concurrency control
#  - No duplicate assignments under concurrent load
#  - Proper Pending state for claims waiting for accounts

# Load Environment vars
source test/integration/integration-test-lib.sh

# Run pre-flight checks
if [ "${SKIP_PREFLIGHT_CHECKS:-false}" != "true" ]; then
    if ! preflightChecks; then
        echo "Pre-flight checks failed. Set SKIP_PREFLIGHT_CHECKS=true to bypass."
        exit $EXIT_FAIL_UNEXPECTED_ERROR
    fi
fi

EXIT_TEST_FAIL_WRONG_READY_COUNT=1
EXIT_TEST_FAIL_WRONG_PENDING_COUNT=2
EXIT_TEST_FAIL_DUPLICATE_ACCOUNT_ASSIGNMENT=3
EXIT_TEST_FAIL_WRONG_POOL_ACCOUNT_ASSIGNED=4
EXIT_TEST_FAIL_CLAIM_UNEXPECTED_STATE=5

declare -A exitCodeMessages
exitCodeMessages[$EXIT_TEST_FAIL_WRONG_READY_COUNT]="Expected exactly 2 claims to be Ready, but got different count."
exitCodeMessages[$EXIT_TEST_FAIL_WRONG_PENDING_COUNT]="Expected exactly 3 claims to be Pending, but got different count."
exitCodeMessages[$EXIT_TEST_FAIL_DUPLICATE_ACCOUNT_ASSIGNMENT]="Two or more claims were assigned the same account (race condition failure)."
exitCodeMessages[$EXIT_TEST_FAIL_WRONG_POOL_ACCOUNT_ASSIGNED]="Claim was assigned an account from the wrong pool."
exitCodeMessages[$EXIT_TEST_FAIL_CLAIM_UNEXPECTED_STATE]="Claim has unexpected state (not Ready or Pending)."

# Test configuration
awsAccountId1="${OSD_STAGING_1_AWS_ACCOUNT_ID}"
awsAccountId2="${OSD_STAGING_2_AWS_ACCOUNT_ID}"
accountCrNamespace="${NAMESPACE}"
testName="test-concurrent-claims-${TEST_START_TIME_SECONDS}"
poolName="${testName}-pool"

# Account CRs
account1Name="${testName}-account-1"
account2Name="${testName}-account-2"

# AccountClaims (create 5 to compete for 2 accounts)
claimBaseName="${testName}-claim"
claimNamespace="${testName}-claims"
numClaims=5

function setupTestPhase {
    echo "=============================================="
    echo "SETUP PHASE: Creating pool with 2 accounts"
    echo "=============================================="

    # Create test namespace for claims
    echo "Creating namespace for AccountClaims: ${claimNamespace}"
    createNamespace "${claimNamespace}" || exit "$?"

    # Create Account CR 1 in pool
    echo "Creating Account CR 1: ${account1Name}"
    createAccountCRInPool "${awsAccountId1}" "${account1Name}" "${accountCrNamespace}" "${poolName}" || exit "$?"

    # Create Account CR 2 in pool
    echo "Creating Account CR 2: ${account2Name}"
    createAccountCRInPool "${awsAccountId2}" "${account2Name}" "${accountCrNamespace}" "${poolName}" || exit "$?"

    # Wait for both accounts to be Ready and Unclaimed
    echo "Waiting for accounts to be Ready and Unclaimed..."
    timeout="${ACCOUNT_READY_TIMEOUT}"

    echo "Waiting for Account 1..."
    waitForAccountReadyAndUnclaimed "${awsAccountId1}" "${account1Name}" "${accountCrNamespace}" "${timeout}" || exit "$?"

    echo "Waiting for Account 2..."
    waitForAccountReadyAndUnclaimed "${awsAccountId2}" "${account2Name}" "${accountCrNamespace}" "${timeout}" || exit "$?"

    echo "Setup complete: 2 accounts ready in pool '${poolName}'"
    exit "$EXIT_PASS"
}

function cleanupTestPhase {
    echo "========================================="
    echo "CLEANUP PHASE: Removing test resources"
    echo "========================================="

    local cleanupExitCode="${EXIT_PASS}"
    local removeFinalizers=true
    timeout="${RESOURCE_DELETE_TIMEOUT}"

    # Delete all AccountClaims
    for i in $(seq 1 ${numClaims}); do
        claimName="${claimBaseName}-${i}"
        echo "Deleting AccountClaim ${i}/${numClaims}: ${claimName}"
        if ! deleteAccountClaimCR "${claimName}" "${claimNamespace}" "${timeout}" $removeFinalizers; then
            echo "Failed to delete AccountClaim - ${claimName}"
            cleanupExitCode="${EXIT_FAIL_UNEXPECTED_ERROR}"
        fi
    done

    # Delete namespace
    echo "Deleting claims namespace..."
    if ! deleteNamespace "${claimNamespace}" "${timeout}" $removeFinalizers; then
        echo "Failed to delete namespace - ${claimNamespace}"
        cleanupExitCode="${EXIT_FAIL_UNEXPECTED_ERROR}"
    fi

    # Delete Account CRs
    echo "Deleting Account CR 1..."
    if ! deleteAccountCR "${awsAccountId1}" "${account1Name}" "${accountCrNamespace}" "${timeout}" $removeFinalizers; then
        echo "Failed to delete Account CR 1 - ${account1Name}"
        cleanupExitCode="${EXIT_FAIL_UNEXPECTED_ERROR}"
    fi

    echo "Deleting Account CR 2..."
    if ! deleteAccountCR "${awsAccountId2}" "${account2Name}" "${accountCrNamespace}" "${timeout}" $removeFinalizers; then
        echo "Failed to delete Account CR 2 - ${account2Name}"
        cleanupExitCode="${EXIT_FAIL_UNEXPECTED_ERROR}"
    fi

    echo "Cleanup complete"
    exit "$cleanupExitCode"
}

function testPhase {
    echo "=================================================="
    echo "TEST PHASE: Testing concurrent AccountClaim race"
    echo "=================================================="

    # Phase 1: Create all claims simultaneously
    echo ""
    echo "--- Phase 1: Creating ${numClaims} AccountClaims simultaneously ---"
    echo "This tests race condition handling in the operator..."

    # Create all claims in parallel using background jobs
    local pids=()
    for i in $(seq 1 ${numClaims}); do
        claimName="${claimBaseName}-${i}"
        echo "Starting creation of claim ${i}/${numClaims}: ${claimName}"

        # Create claim in background
        (
            createAccountClaimCRInPool "${claimName}" "${claimNamespace}" "${poolName}" 2>&1 | sed "s/^/[Claim-${i}] /"
        ) &
        pids+=($!)
    done

    # Wait for all background claim creations to complete
    echo ""
    echo "Waiting for all ${numClaims} claims to be created..."
    for pid in "${pids[@]}"; do
        wait "$pid" || {
            echo "ERROR: Background claim creation failed"
            exit $EXIT_FAIL_UNEXPECTED_ERROR
        }
    done
    echo "All ${numClaims} claims created successfully"

    # Phase 2: Wait for claims to reach final state
    echo ""
    echo "--- Phase 2: Waiting for claims to reach final state ---"
    echo "Waiting ${ACCOUNT_CLAIM_READY_TIMEOUT} for claims to be processed..."

    # Give the operator time to process all claims
    # We expect 2 to become Ready and 3 to stay Pending
    sleep 30

    # Phase 3: Verify claim states and account assignments
    echo ""
    echo "--- Phase 3: Verifying claim states and account assignments ---"

    declare -a readyClaims=()
    declare -a pendingClaims=()
    declare -a assignedAccounts=()

    for i in $(seq 1 ${numClaims}); do
        claimName="${claimBaseName}-${i}"

        # Get claim state
        crYaml=$(generateAccountClaimCRYaml "${claimName}" "${claimNamespace}")
        claimJson=$(ocGetResourceAsJson "${crYaml}")
        state=$(echo "$claimJson" | jq -r '.items[0].status.state // "unknown"')
        accountLink=$(echo "$claimJson" | jq -r '.items[0].spec.accountLink // ""')

        echo "Claim ${i}: ${claimName} - State: ${state}, Account: ${accountLink:-none}"

        case "$state" in
            "Ready")
                readyClaims+=("${claimName}")
                if [ -n "$accountLink" ]; then
                    assignedAccounts+=("${accountLink}")
                fi
                ;;
            "Pending")
                pendingClaims+=("${claimName}")
                ;;
            *)
                echo "ERROR: Claim ${claimName} has unexpected state: ${state}"
                exit $EXIT_TEST_FAIL_CLAIM_UNEXPECTED_STATE
                ;;
        esac
    done

    # Verify counts
    readyCount=${#readyClaims[@]}
    pendingCount=${#pendingClaims[@]}

    echo ""
    echo "Results:"
    echo "  Ready claims:   ${readyCount}/5 (expected: 2)"
    echo "  Pending claims: ${pendingCount}/5 (expected: 3)"

    if [ "$readyCount" -ne 2 ]; then
        echo "ERROR: Expected exactly 2 Ready claims, but got ${readyCount}"
        echo "Ready claims: ${readyClaims[*]}"
        exit $EXIT_TEST_FAIL_WRONG_READY_COUNT
    fi

    if [ "$pendingCount" -ne 3 ]; then
        echo "ERROR: Expected exactly 3 Pending claims, but got ${pendingCount}"
        echo "Pending claims: ${pendingClaims[*]}"
        exit $EXIT_TEST_FAIL_WRONG_PENDING_COUNT
    fi

    # Verify no duplicate account assignments
    echo ""
    echo "--- Phase 4: Verifying no duplicate account assignments ---"

    if [ "${#assignedAccounts[@]}" -ne 2 ]; then
        echo "ERROR: Expected 2 assigned accounts, got ${#assignedAccounts[@]}"
        exit $EXIT_FAIL_UNEXPECTED_ERROR
    fi

    # Check for duplicates
    uniqueAccounts=($(printf '%s\n' "${assignedAccounts[@]}" | sort -u))
    if [ "${#uniqueAccounts[@]}" -ne "${#assignedAccounts[@]}" ]; then
        echo "ERROR: Duplicate account assignments detected!"
        echo "Assigned accounts: ${assignedAccounts[*]}"
        echo "Unique accounts: ${uniqueAccounts[*]}"
        exit $EXIT_TEST_FAIL_DUPLICATE_ACCOUNT_ASSIGNMENT
    fi

    echo "No duplicate assignments found ✓"
    echo "Assigned accounts: ${assignedAccounts[*]}"

    # Verify accounts are from the correct pool
    echo ""
    echo "--- Phase 5: Verifying accounts are from correct pool ---"

    for account in "${assignedAccounts[@]}"; do
        if [ "$account" != "$account1Name" ] && [ "$account" != "$account2Name" ]; then
            echo "ERROR: Account ${account} is not from the test pool!"
            echo "Expected: ${account1Name} or ${account2Name}"
            exit $EXIT_TEST_FAIL_WRONG_POOL_ACCOUNT_ASSIGNED
        fi
    done

    echo "All assigned accounts are from correct pool ✓"

    # Success!
    echo ""
    echo "=========================================="
    echo "ALL TESTS PASSED!"
    echo "=========================================="
    echo "✓ Concurrent claim creation handled correctly"
    echo "✓ Exactly 2 claims became Ready (got accounts)"
    echo "✓ Exactly 3 claims stayed Pending (pool exhausted)"
    echo "✓ No duplicate account assignments (race condition handled)"
    echo "✓ All accounts from correct pool"
    echo ""
    echo "Ready claims:   ${readyClaims[*]}"
    echo "Pending claims: ${pendingClaims[*]}"

    exit "$EXIT_PASS"
}

function explainExitCode {
    local exitCode=$1
    local message=${exitCodeMessages[$exitCode]}
    if [ -n "$message" ]; then
        echo "$message"
    else
        echo "${COMMON_EXIT_CODE_MESSAGES[$exitCode]}"
    fi
}

# Main test execution
PHASE=$1

case $PHASE in
    setup)
        setupTestPhase
        ;;
    cleanup)
        cleanupTestPhase
        ;;
    test)
        testPhase
        ;;
    explain)
        explainExitCode "$2"
        ;;
    *)
        echo "Unknown test phase: '$PHASE'"
        echo "Usage: $0 {setup|test|cleanup|explain <exit_code>}"
        exit 1
        ;;
esac
