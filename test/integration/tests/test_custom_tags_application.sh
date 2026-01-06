#!/usr/bin/env bash

# Test Description:
#  This test validates custom tag application in AccountClaims.
#  Custom tags are used for compliance, billing, and resource organization.
#
#  The test:
#  1. Creates a namespace for the custom tags test
#  2. Creates an AccountClaim with custom tags
#  3. Waits for the claim to become Ready
#  4. Validates the custom tags are set on the AccountClaim
#  5. Validates the custom tags propagated to the linked Account CR
#  6. Validates tag keys and values match expectations
#  7. Cleans up resources
#
#  This validates:
#  - Custom tags are accepted in AccountClaim spec
#  - Custom tags propagate from AccountClaim to Account CR
#  - Tag key-value pairs are preserved correctly
#  - Compliance and billing tags can be applied

source test/integration/integration-test-lib.sh
source test/integration/test_envs

# Run pre-flight checks
if [ "${SKIP_PREFLIGHT_CHECKS:-false}" != "true" ]; then
    if ! preflightChecks; then
        echo "Pre-flight checks failed. Set SKIP_PREFLIGHT_CHECKS=true to bypass."
        exit $EXIT_FAIL_UNEXPECTED_ERROR
    fi
fi

EXIT_TEST_FAIL_NO_CUSTOM_TAGS=1
EXIT_TEST_FAIL_TAG_MISMATCH=2
EXIT_TEST_FAIL_TAG_NOT_PROPAGATED=3
EXIT_TEST_FAIL_INCORRECT_TAG_VALUE=4

declare -A exitCodeMessages
exitCodeMessages[$EXIT_TEST_FAIL_NO_CUSTOM_TAGS]="AccountClaim does not have customTags set."
exitCodeMessages[$EXIT_TEST_FAIL_TAG_MISMATCH]="Custom tags do not match expected values."
exitCodeMessages[$EXIT_TEST_FAIL_TAG_NOT_PROPAGATED]="Custom tags did not propagate to Account CR."
exitCodeMessages[$EXIT_TEST_FAIL_INCORRECT_TAG_VALUE]="Tag value does not match expected value."

tagsClaimName="${CUSTOM_TAGS_CLAIM_NAME:-test-custom-tags-claim}"
tagsNamespace="${CUSTOM_TAGS_NAMESPACE_NAME:-test-custom-tags}"
accountCrNamespace="${NAMESPACE}"

# Expected tags
expectedTag1Key="test-team"
expectedTag1Value="platform-engineering"
expectedTag2Key="test-environment"
expectedTag2Value="integration-test"
expectedTag3Key="test-cost-center"
expectedTag3Value="12345"

function explain {
    exitCode=$1
    echo "${exitCodeMessages[$exitCode]}"
}

function setup {
    echo "========================================================================="
    echo "SETUP: Creating namespace and AccountClaim with custom tags"
    echo "========================================================================="

    echo "Creating namespace: ${tagsNamespace}"
    createNamespace "${tagsNamespace}" || return $?

    echo "Creating AccountClaim with custom tags: ${tagsClaimName}"
    echo "  Tags to apply:"
    echo "    - ${expectedTag1Key}=${expectedTag1Value}"
    echo "    - ${expectedTag2Key}=${expectedTag2Value}"
    echo "    - ${expectedTag3Key}=${expectedTag3Value}"

    local claimYaml
    claimYaml=$(oc process --local -p NAME="${tagsClaimName}" -p NAMESPACE="${tagsNamespace}" -f hack/templates/aws.managed.openshift.io_v1alpha1_customtags_accountclaim_cr.tmpl)
    ocCreateResourceIfNotExists "${claimYaml}" || return $?

    echo "Waiting for AccountClaim to become Ready..."
    timeout="${ACCOUNT_CLAIM_READY_TIMEOUT}"
    waitForAccountClaimCRReadyOrFailed "${tagsClaimName}" "${tagsNamespace}" "${timeout}" || return $?

    echo "✓ Setup complete"
    return 0
}

function test {
    echo "========================================================================="
    echo "TEST: Validating custom tags on AccountClaim and Account CR"
    echo "========================================================================="

    echo "Getting AccountClaim..."
    local claimYaml
    claimYaml=$(generateAccountClaimCRYaml "${tagsClaimName}" "${tagsNamespace}")
    local accClaim
    accClaim=$(ocGetResourceAsJson "${claimYaml}" | jq -r '.items[0]')

    echo ""
    echo "--- Validating AccountClaim Custom Tags ---"

    echo "Checking if customTags field exists..."
    local customTags
    customTags=$(echo "$accClaim" | jq -c '.spec.customTags // []')
    local tagCount
    tagCount=$(echo "$customTags" | jq 'length')

    if [ "$tagCount" -lt 1 ]; then
        echo "ERROR: AccountClaim has no customTags"
        return $EXIT_TEST_FAIL_NO_CUSTOM_TAGS
    fi
    echo "✓ Found ${tagCount} custom tags on AccountClaim"

    echo "Validating tag 1: ${expectedTag1Key}..."
    local tag1Value
    tag1Value=$(echo "$customTags" | jq -r ".[] | select(.key == \"${expectedTag1Key}\").value")
    if [ "$tag1Value" != "${expectedTag1Value}" ]; then
        echo "ERROR: Tag '${expectedTag1Key}' value mismatch (expected '${expectedTag1Value}', got '${tag1Value}')"
        return $EXIT_TEST_FAIL_INCORRECT_TAG_VALUE
    fi
    echo "✓ ${expectedTag1Key}=${tag1Value}"

    echo "Validating tag 2: ${expectedTag2Key}..."
    local tag2Value
    tag2Value=$(echo "$customTags" | jq -r ".[] | select(.key == \"${expectedTag2Key}\").value")
    if [ "$tag2Value" != "${expectedTag2Value}" ]; then
        echo "ERROR: Tag '${expectedTag2Key}' value mismatch (expected '${expectedTag2Value}', got '${tag2Value}')"
        return $EXIT_TEST_FAIL_INCORRECT_TAG_VALUE
    fi
    echo "✓ ${expectedTag2Key}=${tag2Value}"

    echo "Validating tag 3: ${expectedTag3Key}..."
    local tag3Value
    tag3Value=$(echo "$customTags" | jq -r ".[] | select(.key == \"${expectedTag3Key}\").value")
    if [ "$tag3Value" != "${expectedTag3Value}" ]; then
        echo "ERROR: Tag '${expectedTag3Key}' value mismatch (expected '${expectedTag3Value}', got '${tag3Value}')"
        return $EXIT_TEST_FAIL_INCORRECT_TAG_VALUE
    fi
    echo "✓ ${expectedTag3Key}=${tag3Value}"

    echo ""
    echo "--- Validating Tag Propagation to Account CR ---"

    echo "Getting linked Account CR..."
    local accountLink
    accountLink=$(echo "$accClaim" | jq -r '.spec.accountLink')
    local account
    account=$(oc get account "${accountLink}" -n "${accountCrNamespace}" -o json)

    echo "Checking Account CR customTags..."
    local accountCustomTags
    accountCustomTags=$(echo "$account" | jq -c '.spec.customTags // []')
    local accountTagCount
    accountTagCount=$(echo "$accountCustomTags" | jq 'length')

    if [ "$accountTagCount" -lt 1 ]; then
        echo "ERROR: Account CR has no customTags - tags did not propagate"
        return $EXIT_TEST_FAIL_TAG_NOT_PROPAGATED
    fi
    echo "✓ Account CR has ${accountTagCount} custom tags"

    echo "Validating tag propagation: ${expectedTag1Key}..."
    local accountTag1Value
    accountTag1Value=$(echo "$accountCustomTags" | jq -r ".[] | select(.key == \"${expectedTag1Key}\").value")
    if [ "$accountTag1Value" != "${expectedTag1Value}" ]; then
        echo "ERROR: Account tag '${expectedTag1Key}' mismatch (expected '${expectedTag1Value}', got '${accountTag1Value}')"
        return $EXIT_TEST_FAIL_TAG_MISMATCH
    fi
    echo "✓ Account CR: ${expectedTag1Key}=${accountTag1Value}"

    echo "Validating tag propagation: ${expectedTag2Key}..."
    local accountTag2Value
    accountTag2Value=$(echo "$accountCustomTags" | jq -r ".[] | select(.key == \"${expectedTag2Key}\").value")
    if [ "$accountTag2Value" != "${expectedTag2Value}" ]; then
        echo "ERROR: Account tag '${expectedTag2Key}' mismatch (expected '${expectedTag2Value}', got '${accountTag2Value}')"
        return $EXIT_TEST_FAIL_TAG_MISMATCH
    fi
    echo "✓ Account CR: ${expectedTag2Key}=${accountTag2Value}"

    echo "Validating tag propagation: ${expectedTag3Key}..."
    local accountTag3Value
    accountTag3Value=$(echo "$accountCustomTags" | jq -r ".[] | select(.key == \"${expectedTag3Key}\").value")
    if [ "$accountTag3Value" != "${expectedTag3Value}" ]; then
        echo "ERROR: Account tag '${expectedTag3Key}' mismatch (expected '${expectedTag3Value}', got '${accountTag3Value}')"
        return $EXIT_TEST_FAIL_TAG_MISMATCH
    fi
    echo "✓ Account CR: ${expectedTag3Key}=${accountTag3Value}"

    echo ""
    echo "========================================================================="
    echo "CUSTOM TAGS TEST PASSED!"
    echo "========================================================================="
    echo "✓ AccountClaim custom tags set correctly"
    echo "✓ All ${tagCount} custom tags have correct values"
    echo "✓ Custom tags propagated to Account CR"
    echo "✓ Tag key-value pairs preserved during propagation"

    return 0
}

function cleanup {
    echo "========================================================================="
    echo "CLEANUP: Removing test resources"
    echo "========================================================================="

    local cleanupExitCode=0

    echo "Deleting AccountClaim..."
    deleteAccountClaimCR "${tagsClaimName}" "${tagsNamespace}" "${RESOURCE_DELETE_TIMEOUT}" true 2>/dev/null || {
        echo "WARNING: Failed to delete AccountClaim"
        cleanupExitCode=$EXIT_FAIL_UNEXPECTED_ERROR
    }

    echo "Deleting namespace..."
    deleteNamespace "${tagsNamespace}" "${RESOURCE_DELETE_TIMEOUT}" true 2>/dev/null || {
        echo "WARNING: Failed to delete namespace"
        cleanupExitCode=$EXIT_FAIL_UNEXPECTED_ERROR
    }

    echo "✓ Cleanup complete"
    return $cleanupExitCode
}

# Handle the explain command
if [ "${1:-}" == "explain" ]; then
    explain "$2"
    exit 0
fi

# Main test execution
case "${1:-}" in
    setup)
        setup
        ;;
    test)
        test
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo "Usage: $0 {setup|test|cleanup|explain <exit_code>}"
        exit 1
        ;;
esac
