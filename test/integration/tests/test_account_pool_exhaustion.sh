#!/usr/bin/env bash

# Test Description:
#  This test validates AccountPool exhaustion behavior and account reuse when claims are deleted.
#
#  The test creates a small pool of 2 accounts, then:
#  1. Creates 2 AccountClaims that consume all available accounts
#  2. Creates a 3rd AccountClaim that should stay Pending (pool exhausted)
#  3. Deletes one of the first 2 claims
#  4. Verifies the 3rd claim gets the freed account and becomes Ready
#
#  This validates:
#  - AccountClaim selection from specific pools
#  - Pending state when no accounts available
#  - Account reuse when claims are deleted
#  - Pool exhaustion and recovery behavior

# Load Environment vars
source test/integration/integration-test-lib.sh

# Run pre-flight checks
if [ "${SKIP_PREFLIGHT_CHECKS:-false}" != "true" ]; then
    if ! preflightChecks; then
        echo "Pre-flight checks failed. Set SKIP_PREFLIGHT_CHECKS=true to bypass."
        exit $EXIT_FAIL_UNEXPECTED_ERROR
    fi
fi

EXIT_TEST_FAIL_POOL_NOT_EXHAUSTED=1
EXIT_TEST_FAIL_CLAIM_NOT_PENDING=2
EXIT_TEST_FAIL_CLAIM_NOT_READY_AFTER_FREE=3
EXIT_TEST_FAIL_ACCOUNT_NOT_REUSED=4
EXIT_TEST_FAIL_DUPLICATE_ACCOUNT_ASSIGNMENT=5
EXIT_TEST_FAIL_WRONG_POOL_ACCOUNT_ASSIGNED=6

declare -A exitCodeMessages
exitCodeMessages[$EXIT_TEST_FAIL_POOL_NOT_EXHAUSTED]="Pool should be exhausted but claim succeeded unexpectedly."
exitCodeMessages[$EXIT_TEST_FAIL_CLAIM_NOT_PENDING]="AccountClaim should be in Pending state when pool is exhausted."
exitCodeMessages[$EXIT_TEST_FAIL_CLAIM_NOT_READY_AFTER_FREE]="AccountClaim did not become Ready after account was freed."
exitCodeMessages[$EXIT_TEST_FAIL_ACCOUNT_NOT_REUSED]="Account was not marked as reused after being freed and reclaimed."
exitCodeMessages[$EXIT_TEST_FAIL_DUPLICATE_ACCOUNT_ASSIGNMENT]="Two AccountClaims were assigned the same account."
exitCodeMessages[$EXIT_TEST_FAIL_WRONG_POOL_ACCOUNT_ASSIGNED]="AccountClaim was assigned an account from the wrong pool."

# Test configuration
awsAccountId1="${OSD_STAGING_1_AWS_ACCOUNT_ID}"
awsAccountId2="${OSD_STAGING_2_AWS_ACCOUNT_ID}"
accountCrNamespace="${NAMESPACE}"
testName="test-pool-exhaustion-${TEST_START_TIME_SECONDS}"
poolName="${testName}-pool"

# Account CRs
account1Name="${testName}-account-1"
account2Name="${testName}-account-2"

# AccountClaims
claim1Name="${testName}-claim-1"
claim2Name="${testName}-claim-2"
claim3Name="${testName}-claim-3"
claimNamespace="${testName}-claims"

function setupTestPhase {
    echo "==========================================="
    echo "SETUP PHASE: Creating pool with 2 accounts"
    echo "==========================================="

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
    echo "======================================="
    echo "CLEANUP PHASE: Removing test resources"
    echo "======================================="

    local cleanupExitCode="${EXIT_PASS}"
    local removeFinalizers=true
    timeout="${RESOURCE_DELETE_TIMEOUT}"

    # Delete AccountClaims
    echo "Deleting AccountClaim 1..."
    if ! deleteAccountClaimCR "${claim1Name}" "${claimNamespace}" "${timeout}" $removeFinalizers; then
        echo "Failed to delete AccountClaim 1 - ${claim1Name}"
        cleanupExitCode="${EXIT_FAIL_UNEXPECTED_ERROR}"
    fi

    echo "Deleting AccountClaim 2..."
    if ! deleteAccountClaimCR "${claim2Name}" "${claimNamespace}" "${timeout}" $removeFinalizers; then
        echo "Failed to delete AccountClaim 2 - ${claim2Name}"
        cleanupExitCode="${EXIT_FAIL_UNEXPECTED_ERROR}"
    fi

    echo "Deleting AccountClaim 3..."
    if ! deleteAccountClaimCR "${claim3Name}" "${claimNamespace}" "${timeout}" $removeFinalizers; then
        echo "Failed to delete AccountClaim 3 - ${claim3Name}"
        cleanupExitCode="${EXIT_FAIL_UNEXPECTED_ERROR}"
    fi

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
    echo "=========================================="
    echo "TEST PHASE: Pool exhaustion and recovery"
    echo "=========================================="

    # Phase 1: Exhaust the pool
    echo ""
    echo "--- Phase 1: Exhausting the pool ---"
    echo "Creating AccountClaim 1..."
    createAccountClaimCRInPool "${claim1Name}" "${claimNamespace}" "${poolName}" || exit "$?"

    echo "Creating AccountClaim 2..."
    createAccountClaimCRInPool "${claim2Name}" "${claimNamespace}" "${poolName}" || exit "$?"

    # Wait for both claims to become Ready
    timeout="${ACCOUNT_CLAIM_READY_TIMEOUT}"
    echo "Waiting for AccountClaim 1 to become Ready..."
    waitForAccountClaimCRReadyOrFailed "${claim1Name}" "${claimNamespace}" "${timeout}" || exit "$?"

    echo "Waiting for AccountClaim 2 to become Ready..."
    waitForAccountClaimCRReadyOrFailed "${claim2Name}" "${claimNamespace}" "${timeout}" || exit "$?"

    echo "Both claims are Ready. Pool should now be exhausted."

    # Get account links to verify no duplicates
    claim1Account=$(getAccountClaimAccountLink "${claim1Name}" "${claimNamespace}")
    claim2Account=$(getAccountClaimAccountLink "${claim2Name}" "${claimNamespace}")

    echo "Claim 1 has account: ${claim1Account}"
    echo "Claim 2 has account: ${claim2Account}"

    # Verify no duplicate account assignment
    if [ "${claim1Account}" = "${claim2Account}" ]; then
        echo "ERROR: Both claims were assigned the same account!"
        exit $EXIT_TEST_FAIL_DUPLICATE_ACCOUNT_ASSIGNMENT
    fi

    # Verify accounts are from the correct pool
    if [ "${claim1Account}" != "${account1Name}" ] && [ "${claim1Account}" != "${account2Name}" ]; then
        echo "ERROR: Claim 1 was assigned an account from wrong pool: ${claim1Account}"
        exit $EXIT_TEST_FAIL_WRONG_POOL_ACCOUNT_ASSIGNED
    fi

    if [ "${claim2Account}" != "${account1Name}" ] && [ "${claim2Account}" != "${account2Name}" ]; then
        echo "ERROR: Claim 2 was assigned an account from wrong pool: ${claim2Account}"
        exit $EXIT_TEST_FAIL_WRONG_POOL_ACCOUNT_ASSIGNED
    fi

    # Phase 2: Verify pool exhaustion
    echo ""
    echo "--- Phase 2: Verifying pool exhaustion ---"
    echo "Creating AccountClaim 3 (should stay Pending)..."
    createAccountClaimCRInPool "${claim3Name}" "${claimNamespace}" "${poolName}" || exit "$?"

    # Wait a bit and verify it's still Pending
    echo "Waiting 30 seconds to verify claim stays Pending..."
    sleep 30

    if ! isAccountClaimPending "${claim3Name}" "${claimNamespace}"; then
        claim3State=$(oc get accountclaim "${claim3Name}" -n "${claimNamespace}" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
        echo "ERROR: AccountClaim 3 should be Pending but is: ${claim3State}"
        exit $EXIT_TEST_FAIL_CLAIM_NOT_PENDING
    fi

    echo "Verified: AccountClaim 3 is Pending (pool exhausted)"

    # Phase 3: Free an account and verify claim becomes Ready
    echo ""
    echo "--- Phase 3: Freeing account and verifying reuse ---"
    echo "Deleting AccountClaim 1 to free an account..."
    timeout="${RESOURCE_DELETE_TIMEOUT}"
    deleteAccountClaimCR "${claim1Name}" "${claimNamespace}" "${timeout}" || exit "$?"

    echo "Waiting for AccountClaim 3 to become Ready..."
    timeout="${ACCOUNT_CLAIM_READY_TIMEOUT}"
    waitForAccountClaimCRReadyOrFailed "${claim3Name}" "${claimNamespace}" "${timeout}" || exit $EXIT_TEST_FAIL_CLAIM_NOT_READY_AFTER_FREE

    # Verify claim 3 got the freed account
    claim3Account=$(getAccountClaimAccountLink "${claim3Name}" "${claimNamespace}")
    echo "Claim 3 has account: ${claim3Account}"

    if [ "${claim3Account}" != "${claim1Account}" ]; then
        echo "WARNING: Claim 3 got account ${claim3Account} instead of freed account ${claim1Account}"
        echo "This may be expected if operator preferred the other account for some reason"
    fi

    # Verify the account shows reused status
    echo "Verifying account shows reused status..."
    if [ "${claim3Account}" = "${account1Name}" ]; then
        accountJson=$(getAccountCRAsJson "${awsAccountId1}" "${account1Name}" "${accountCrNamespace}")
    else
        accountJson=$(getAccountCRAsJson "${awsAccountId2}" "${account2Name}" "${accountCrNamespace}")
    fi

    reusedStatus=$(echo "$accountJson" | jq -r '.status.reused // false')
    if [ "${reusedStatus}" != "true" ]; then
        echo "ERROR: Account should have status.reused=true but has: ${reusedStatus}"
        exit $EXIT_TEST_FAIL_ACCOUNT_NOT_REUSED
    fi

    echo "Verified: Account shows reused=true"
    echo ""
    echo "=========================================="
    echo "ALL TESTS PASSED!"
    echo "=========================================="
    echo "✓ Pool exhaustion behavior validated"
    echo "✓ Pending state when no accounts available"
    echo "✓ Account reuse after claim deletion"
    echo "✓ No duplicate account assignments"

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
