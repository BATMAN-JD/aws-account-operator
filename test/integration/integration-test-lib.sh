#!/usr/bin/env bash

# Default timeouts (can be overridden by environment variables)
export ACCOUNT_READY_TIMEOUT="${ACCOUNT_READY_TIMEOUT:-3m}"
export ACCOUNT_CLAIM_READY_TIMEOUT="${ACCOUNT_CLAIM_READY_TIMEOUT:-1m}"
export RESOURCE_DELETE_TIMEOUT="${RESOURCE_DELETE_TIMEOUT:-30s}"

# Retry configuration for transient errors
export MAX_RETRIES="${MAX_RETRIES:-3}"
export INITIAL_RETRY_DELAY="${INITIAL_RETRY_DELAY:-2}"

export EXIT_PASS=0
export EXIT_FAIL_UNEXPECTED_ERROR=99
export EXIT_SKIP=98
export EXIT_TIMEOUT=97
export EXIT_TEST_FAIL_ACCOUNT_PROVISIONING_FAILED=96
export EXIT_TEST_FAIL_ACCOUNT_UNEXPECTED_STATUS_AFTER_TIMEOUT=95
export EXIT_TEST_FAIL_ACCOUNT_CLAIM_PROVISIONING_FAILED=94
export EXIT_TEST_FAIL_ACCOUNT_CLAIM_UNEXPECTED_STATUS_AFTER_TIMEOUT=93
export EXIT_TEST_FAIL_CLUSTER_RESOURCE_NOT_DELETED=92

declare -A COMMON_EXIT_CODE_MESSAGES
export COMMON_EXIT_CODE_MESSAGES
COMMON_EXIT_CODE_MESSAGES[$EXIT_PASS]="PASS"
COMMON_EXIT_CODE_MESSAGES[$EXIT_FAIL_UNEXPECTED_ERROR]="Unexpected error. Check test logs for more details."
COMMON_EXIT_CODE_MESSAGES[$EXIT_TIMEOUT]="Timeout waiting for some condition to be met. Check test logs for more details."
COMMON_EXIT_CODE_MESSAGES[$EXIT_SKIP]="Test/phase execution was skipped. Check test logs for more details."
COMMON_EXIT_CODE_MESSAGES[$EXIT_TEST_FAIL_ACCOUNT_UNEXPECTED_STATUS_AFTER_TIMEOUT]="Condition Timeout - Account CR has an unexpected status (not Ready or Failed). Consider increasing the ACCOUNT_READY_TIMEOUT timeout. Check AAO logs for more details."
COMMON_EXIT_CODE_MESSAGES[$EXIT_TEST_FAIL_ACCOUNT_PROVISIONING_FAILED]="Account CR has a status of failed. Check AAO logs for more details."
COMMON_EXIT_CODE_MESSAGES[$EXIT_TEST_FAIL_ACCOUNT_CLAIM_UNEXPECTED_STATUS_AFTER_TIMEOUT]="Condition Timeout - AccountClaim CR has an unexpected status (not Ready or Failed). Consider increasing ACCOUNT_CLAIM_READY_TIMEOUT timeouts. Check AAO logs for more details."
COMMON_EXIT_CODE_MESSAGES[$EXIT_TEST_FAIL_ACCOUNT_CLAIM_PROVISIONING_FAILED]="AccountClaim CR has a status of failed. Check AAO logs for more details."
COMMON_EXIT_CODE_MESSAGES[$EXIT_TEST_FAIL_CLUSTER_RESOURCE_NOT_DELETED]="Condition Timeout - Cluster resource not deleted. Consider increasing the RESOURCE_DELETE_TIMEOUT timeout, however this usually means a resource finalizer is unable to complete due to some error. Check AAO logs for more details."


#
# Retry function with exponential backoff for handling transient errors
# Usage: retryWithBackoff <max_attempts> <command> [args...]
# Returns: exit code of the command (0 on success, non-zero on failure after all retries)
#
function retryWithBackoff {
    local maxAttempts=$1
    shift
    local attempt=1
    local delay=$INITIAL_RETRY_DELAY
    local exitCode=0

    while [ $attempt -le "$maxAttempts" ]; do
        # Execute the command
        if "$@"; then
            return 0
        fi
        exitCode=$?

        if [ $attempt -lt "$maxAttempts" ]; then
            echo "Command failed (attempt $attempt/$maxAttempts). Retrying in ${delay}s..." 1>&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done

    echo "Command failed after $maxAttempts attempts." 1>&2
    return $exitCode
}

#
# Helper function to check if an error message indicates a transient network error
#
function isTransientError {
    local errorOutput=$1
    if echo "$errorOutput" | grep -qE "http2: client connection lost|TLS handshake timeout|connection refused|connection reset|unable to decode"; then
        return 0
    fi
    return 1
}

#
# Pre-flight checks to validate test environment
# Returns 0 if all checks pass, non-zero otherwise
#
function preflightChecks {
    local failedChecks=0

    echo "Running pre-flight checks..."

    # Check required tools
    echo "Checking required tools..."
    for tool in oc jq aws; do
        if ! command -v "$tool" &>/dev/null; then
            echo "ERROR: Required tool '$tool' not found in PATH" 1>&2
            failedChecks=$((failedChecks + 1))
        else
            echo "  ✓ $tool found"
        fi
    done

    # Check cluster connectivity
    echo "Checking cluster connectivity..."
    if ! retryWithBackoff 2 oc version &>/dev/null; then
        echo "ERROR: Cannot connect to OpenShift cluster. Check your oc login status." 1>&2
        failedChecks=$((failedChecks + 1))
    else
        echo "  ✓ Connected to cluster"
    fi

    # Check if we can access the operator namespace
    if [ -n "${NAMESPACE:-}" ]; then
        echo "Checking access to operator namespace: ${NAMESPACE}..."
        if ! retryWithBackoff 2 oc get namespace "${NAMESPACE}" &>/dev/null; then
            echo "WARNING: Cannot access namespace '${NAMESPACE}'. It may need to be created." 1>&2
        else
            echo "  ✓ Namespace '${NAMESPACE}' accessible"
        fi
    fi

    # Check AWS CLI configuration (non-blocking warning)
    echo "Checking AWS CLI configuration..."
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "WARNING: AWS CLI not configured or credentials invalid. Some tests may fail." 1>&2
    else
        echo "  ✓ AWS CLI configured"
    fi

    # Check required environment variables (these are test-specific, so just warnings)
    echo "Checking recommended environment variables..."
    local envVars=("OSD_STAGING_1_AWS_ACCOUNT_ID" "OSD_STAGING_2_AWS_ACCOUNT_ID" "NAMESPACE")
    for var in "${envVars[@]}"; do
        if [ -z "${!var:-}" ]; then
            echo "WARNING: Environment variable '$var' not set. Some tests may fail." 1>&2
        else
            echo "  ✓ $var is set"
        fi
    done

    if [ $failedChecks -gt 0 ]; then
        echo "Pre-flight checks failed with $failedChecks critical errors." 1>&2
        return 1
    fi

    echo "Pre-flight checks passed."
    return 0
}

function ocCreateResourceIfNotExists {
    local crYaml=$1
    echo -e "\nCREATE RESOURCE:\n${crYaml}" 1>&2

    # Check if resource exists (with retry for transient errors)
    local resourceExists=false
    if retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc get -f - &>/dev/null"; then
        resourceExists=true
    fi

    if [ "$resourceExists" = false ]; then
        # Resource doesn't exist, try to create it (with retry)
        if ! retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc apply -f -"; then
            echo "Failed to create cluster resource after $MAX_RETRIES attempts"
            return $EXIT_FAIL_UNEXPECTED_ERROR
        fi
    else
        echo "Resource already exists on cluster and *will not* be re-created using provided yaml."
    fi
    return 0
}


# timeout uses oc's timeout syntax (e.g. 30s, 1m, 2h)
# if removeFinalizers is true, it will remove finalizers before trying to delete the resource
function ocDeleteResourceIfExists {
    local crYaml=$1
    local timeout=$2
    local removeFinalizers=${3:-false}
    echo -e "\nDELETE RESOURCE:\n${crYaml}" 1>&2

    # Check if resource exists (with retry for transient errors)
    local resourceExists=false
    if retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc get -f - &>/dev/null"; then
        resourceExists=true
    fi

    if [ "$resourceExists" = true ]; then
        if $removeFinalizers; then
            echo "Removing finalizers before deletion..."
            if ! retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc patch -p '{\"metadata\":{\"finalizers\":null}}' --type=merge -f -"; then
                echo "Warning: Failed to remove finalizers, continuing with delete attempt..."
            fi
        fi

        # Try to delete the resource (with retry)
        if ! retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc delete --now --ignore-not-found --timeout='${timeout}' -f -"; then
            echo "Failed to delete cluster resource after $MAX_RETRIES attempts"
            return $EXIT_TEST_FAIL_CLUSTER_RESOURCE_NOT_DELETED
        fi
    fi

    # Verify resource is actually deleted (with retry)
    if retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc get -f - &>/dev/null"; then
        echo "Cluster resource still exists after delete attempt."
        return "$EXIT_TEST_FAIL_CLUSTER_RESOURCE_NOT_DELETED"
    else
        return 0
    fi
}

# see `oc wait --help` for details on the --for flag
# timeout uses oc's timeout syntax (e.g. 30s, 1m, 2h) 
function ocWaitForResourceCondition {
    local crYaml=$1
    local timeout=$2
    local forCondition=$3

    # oc wait doesnt seem to like when the resource doesnt exist at all
    if echo "${crYaml}" | oc get -f - &>/dev/null; then 
        echo "${crYaml}" | oc wait --for="${forCondition}" --timeout="${timeout}" -f -
        return $?
    else
        echo "Cluster resource does not exist. Cannot wait for condition."
        return $EXIT_FAIL_UNEXPECTED_ERROR
    fi    
}

# Note: fetching resources this way returns results wrapped in a list:
# {
#    "apiVersion": "v1",
#    "kind": "List",
#    "items": [
#        {
#            "apiVersion": "aws.managed.openshift.io/v1alpha1",
#            "kind": "Account",
#            ...
#        }
#    ]
# }
function ocGetResourceAsJson {
    local crYaml=$1
    retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc get -f - -o json"
}

#
# Force delete a resource by removing finalizers and using --force --grace-period=0
# This should only be used as a last resort when normal deletion fails
# Usage: ocForceDeleteResource <crYaml>
#
function ocForceDeleteResource {
    local crYaml=$1
    echo -e "\nFORCE DELETING RESOURCE (last resort):\n${crYaml}" 1>&2

    # Check if resource still exists
    if ! retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc get -f - &>/dev/null"; then
        echo "Resource no longer exists, nothing to force delete."
        return 0
    fi

    # Remove finalizers
    echo "Forcefully removing all finalizers..."
    retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc patch -p '{\"metadata\":{\"finalizers\":null}}' --type=merge -f -" || true

    # Force delete with zero grace period
    echo "Force deleting with --grace-period=0..."
    if retryWithBackoff "$MAX_RETRIES" bash -c "echo '${crYaml}' | oc delete --force --grace-period=0 --ignore-not-found -f -"; then
        echo "Resource force deleted successfully."
        return 0
    else
        echo "Failed to force delete resource even after removing finalizers."
        return $EXIT_TEST_FAIL_CLUSTER_RESOURCE_NOT_DELETED
    fi
}

function getNamespaceYaml {
    local namespace=$1
    local template='hack/templates/namespace.tmpl'
    oc process --local -p NAME="${namespace}" -f ${template}
}

function createNamespace {
    local namespace=$1
    local crYaml=$(getNamespaceYaml "${namespace}")
    ocCreateResourceIfNotExists "${crYaml}"
    return $?
}

# if removeFinalizers is true, it will attempt to remove finalizers and delete again if the first delete fails
function deleteNamespace {
    local namespace=$1
    local timeout=$2
    local removeFinalizers=${3:-false}
    local crYaml=$(getNamespaceYaml "${namespace}")
    ocDeleteResourceIfExists "${crYaml}" "${timeout}"
    deleteSuccess=$?
    if [ $deleteSuccess -ne 0 ] && [ "$removeFinalizers" = true ]; then
        echo "Failed to delete resource, retrying with finalizers removed."
        ocDeleteResourceIfExists "${crYaml}" "${timeout}" true
        deleteSuccess=$?
    fi
    return $deleteSuccess
}

function generateAccountCRYaml {
    local awsAccountId=$1
    local accountCrName=$2
    local accountCrNamespace=$3
    local template='hack/templates/aws.managed.openshift.io_v1alpha1_account.tmpl'
    oc process --local -p AWS_ACCOUNT_ID="${awsAccountId}" -p ACCOUNT_CR_NAME="${accountCrName}" -p NAMESPACE="${accountCrNamespace}" -f ${template}
}

function createAccountCR {
    local awsAccountId=$1
    local accountCrName=$2
    local accountCrNamespace=$3
    local crYaml=$(generateAccountCRYaml "${awsAccountId}" "${accountCrName}" "${accountCrNamespace}")
    ocCreateResourceIfNotExists "${crYaml}"
    return $?
}

function deleteAccountCR {
    local awsAccountId=$1
    local accountCrName=$2
    local accountCrNamespace=$3
    local timeout=$4
    local removeFinalizers=${5:-false}
    local crYaml=$(generateAccountCRYaml "${awsAccountId}" "${accountCrName}" "${accountCrNamespace}")
    ocDeleteResourceIfExists "${crYaml}" "${timeout}"
    deleteSuccess=$?
    if [ $deleteSuccess -ne 0 ] && [ "$removeFinalizers" = true ]; then
        echo "Failed to delete resource, retrying with finalizers removed."
        ocDeleteResourceIfExists "${crYaml}" "${timeout}" true
        deleteSuccess=$?
    fi
    return $deleteSuccess
}

function generateAccountClaimCRYaml {
    local accountClaimCrName=$1
    local accountClaimCrNamespace=$2
    local template='hack/templates/aws.managed.openshift.io_v1alpha1_accountclaim_cr.tmpl'
    oc process --local -p NAME="${accountClaimCrName}" -p NAMESPACE="${accountClaimCrNamespace}" -f ${template}
}

function createAccountClaimCR {
    local accountClaimCrName=$1
    local accountClaimCrNamespace=$2
    local crYaml=$(generateAccountClaimCRYaml "${accountClaimCrName}" "${accountClaimCrNamespace}")
    ocCreateResourceIfNotExists "${crYaml}"
    return $?
}

function deleteAccountClaimCR {
    local accountClaimCrName=$1
    local accountClaimCrNamespace=$2
    local timeout=$3
    local removeFinalizers=${4:-false}
    local crYaml=$(generateAccountClaimCRYaml "${accountClaimCrName}" "${accountClaimCrNamespace}")
    ocDeleteResourceIfExists "${crYaml}" "${timeout}"
    deleteSuccess=$?
    if [ $deleteSuccess -ne 0 ] && [ "$removeFinalizers" = true ]; then
        echo "Failed to delete resource, retrying with finalizers removed."
        ocDeleteResourceIfExists "${crYaml}" "${timeout}" true
        deleteSuccess=$?
    fi
    return $deleteSuccess
}

function getAccountCRAsJson {
    local awsAccountId=$1
    local accountCrName=$2
    local accountCrNamespace=$3
    local crYaml=$(generateAccountCRYaml "${awsAccountId}" "${accountCrName}" "${accountCrNamespace}")
    ocGetResourceAsJson "${crYaml}" | jq -r '.items[0]'
}

function waitForAccountCRReadyOrFailed {
    local awsAccountId=$1
    local accountCrName=$2
    local accountCrNamespace=$3
    local timeout=$4
    local crYaml=$(generateAccountCRYaml "${awsAccountId}" "${accountCrName}" "${accountCrNamespace}")
    
    echo -e "\nWaiting for Account CR to become ready (timeout: ${timeout})"
    if ! ocWaitForResourceCondition "${crYaml}" "${timeout}" "condition=Ready"; then
        if status=$(ocGetResourceAsJson "${crYaml}" | jq -r '.items[0].status.state'); then
            if [ "${status}" == "Failed" ]; then
                echo "Account CR has a status of failed. Check AAO logs for more details."
                return $EXIT_TEST_FAIL_ACCOUNT_PROVISIONING_FAILED
            else
                echo "Unexpected Account CR status after timeout: ${status}"
                return $EXIT_TEST_FAIL_ACCOUNT_UNEXPECTED_STATUS_AFTER_TIMEOUT
            fi
        else
            return $EXIT_FAIL_UNEXPECTED_ERROR
        fi
    fi
    return 0
}

function waitForAccountClaimCRReadyOrFailed {
    local accountClaimCrName=$1
    local accountClaimCrNamespace=$2
    local timeout=$3
    local crYaml=$(generateAccountClaimCRYaml "${accountClaimCrName}" "${accountClaimCrNamespace}")

    echo "Waiting for AccountClaim CR to become ready (timeout: ${timeout})"

    # oc wait --for condition=Ready looks for an entry in the status.conditions array with a type of Ready and a status of True
    # this works for Account CRs, however, even though we set .status.state=Ready on AccountClaim CRs, we dont actually add a
    # "Ready" condition entry to the .status.conditions array. We can use --for=jsonpath={.status.state}=Ready instead, however,
    # prow infra has an old version of oc that doesnt support the jsonpath queries and we get an error.
    if ! ocWaitForResourceCondition "${crYaml}" "${timeout}" "condition=Claimed"; then
        if status=$(ocGetResourceAsJson "${crYaml}" | jq -r '.items[0].status.state'); then
            if [ "${status}" == "Failed" ]; then
                echo "AccountClaim CR has a status of failed. Check AAO logs for more details."
                return $EXIT_TEST_FAIL_ACCOUNT_CLAIM_PROVISIONING_FAILED
            else
                echo "Unexpected AccountClaim CR status after timeout: ${status}"
                return $EXIT_TEST_FAIL_ACCOUNT_CLAIM_UNEXPECTED_STATUS_AFTER_TIMEOUT
            fi
        else
            return $EXIT_FAIL_UNEXPECTED_ERROR
        fi
    fi
    return 0
}

#
# Pool-specific helper functions for pool exhaustion testing
#

# Create an Account CR and patch it to belong to a specific pool
function createAccountCRInPool {
    local awsAccountId=$1
    local accountCrName=$2
    local accountCrNamespace=$3
    local poolName=$4

    echo "Creating Account CR ${accountCrName} in pool ${poolName}"

    # First create the Account CR normally
    if ! createAccountCR "${awsAccountId}" "${accountCrName}" "${accountCrNamespace}"; then
        return $?
    fi

    # Then patch it to add the pool name
    echo "Patching Account CR to set pool: ${poolName}"
    if ! retryWithBackoff "$MAX_RETRIES" oc patch account "${accountCrName}" -n "${accountCrNamespace}" \
        --type=merge -p "{\"spec\":{\"accountPool\":\"${poolName}\"}}"; then
        echo "Failed to patch Account CR with pool name"
        return $EXIT_FAIL_UNEXPECTED_ERROR
    fi

    return 0
}

# Wait for Account CR to be Ready AND Unclaimed
function waitForAccountReadyAndUnclaimed {
    local awsAccountId=$1
    local accountCrName=$2
    local accountCrNamespace=$3
    local timeout=$4

    echo "Waiting for Account ${accountCrName} to be Ready and Unclaimed (timeout: ${timeout})"

    # First wait for it to be Ready
    if ! waitForAccountCRReadyOrFailed "${awsAccountId}" "${accountCrName}" "${accountCrNamespace}" "${timeout}"; then
        return $?
    fi

    # Then verify it's unclaimed
    local accountJson
    accountJson=$(getAccountCRAsJson "${awsAccountId}" "${accountCrName}" "${accountCrNamespace}")
    local claimed=$(echo "$accountJson" | jq -r '.status.claimed // false')

    if [ "$claimed" != "false" ]; then
        echo "Account ${accountCrName} is Ready but already claimed"
        return $EXIT_FAIL_UNEXPECTED_ERROR
    fi

    echo "Account ${accountCrName} is Ready and Unclaimed"
    return 0
}

# Generate AccountClaim CR YAML with specific pool
function generateAccountClaimCRYamlWithPool {
    local accountClaimCrName=$1
    local accountClaimCrNamespace=$2
    local poolName=$3
    local template='hack/templates/aws.managed.openshift.io_v1alpha1_accountclaim_cr.tmpl'

    # Generate base YAML then patch it with pool name
    local baseYaml
    baseYaml=$(oc process --local -p NAME="${accountClaimCrName}" -p NAMESPACE="${accountClaimCrNamespace}" -f ${template})

    # Add accountPool field to spec
    echo "$baseYaml" | sed "s|spec:|spec:\n    accountPool: \"${poolName}\"|"
}

# Create AccountClaim CR with specific pool
function createAccountClaimCRInPool {
    local accountClaimCrName=$1
    local accountClaimCrNamespace=$2
    local poolName=$3

    echo "Creating AccountClaim ${accountClaimCrName} in pool ${poolName}"
    local crYaml
    crYaml=$(generateAccountClaimCRYamlWithPool "${accountClaimCrName}" "${accountClaimCrNamespace}" "${poolName}")
    ocCreateResourceIfNotExists "${crYaml}"
    return $?
}

# Check if AccountClaim is in Pending state
function isAccountClaimPending {
    local claimName=$1
    local claimNamespace=$2

    local crYaml
    crYaml=$(generateAccountClaimCRYaml "${claimName}" "${claimNamespace}")
    local state
    state=$(ocGetResourceAsJson "${crYaml}" | jq -r '.items[0].status.state // ""')

    if [ "$state" = "Pending" ]; then
        return 0
    else
        return 1
    fi
}

# Get the account link from an AccountClaim
function getAccountClaimAccountLink {
    local claimName=$1
    local claimNamespace=$2

    local crYaml
    crYaml=$(generateAccountClaimCRYaml "${claimName}" "${claimNamespace}")
    ocGetResourceAsJson "${crYaml}" | jq -r '.items[0].spec.accountLink // ""'
}

# Check if an Account is claimed
function isAccountClaimed {
    local awsAccountId=$1
    local accountCrName=$2
    local accountCrNamespace=$3

    local accountJson
    accountJson=$(getAccountCRAsJson "${awsAccountId}" "${accountCrName}" "${accountCrNamespace}")
    local claimed
    claimed=$(echo "$accountJson" | jq -r '.status.claimed // false')

    if [ "$claimed" = "true" ]; then
        return 0
    else
        return 1
    fi
}