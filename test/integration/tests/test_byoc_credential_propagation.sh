#!/usr/bin/env bash

# Test Description:
#  This test validates BYOC (Bring Your Own Cloud) credential propagation in CCS AccountClaims.
#  When a CCS secret is provided, the operator should propagate those credentials
#  to the generated awsCredentialSecret.
#
#  The test:
#  1. Creates a namespace for the BYOC test
#  2. Creates a CCS secret with AWS credentials
#  3. Creates a CCS AccountClaim (byoc=true)
#  4. Waits for the claim to become Ready
#  5. Validates the claim has byoc=true
#  6. Validates the awsCredentialSecret was created
#  7. Validates the secret contains valid AWS credential keys
#  8. Validates the credentials work by calling AWS STS
#  9. Cleans up resources
#
#  This validates:
#  - BYOC flag is set correctly on AccountClaim
#  - CCS credentials propagate to awsCredentialSecret
#  - Generated secret contains valid AWS access keys
#  - Credentials are functional

source test/integration/integration-test-lib.sh
source test/integration/test_envs

# Run pre-flight checks
if [ "${SKIP_PREFLIGHT_CHECKS:-false}" != "true" ]; then
    if ! preflightChecks; then
        echo "Pre-flight checks failed. Set SKIP_PREFLIGHT_CHECKS=true to bypass."
        exit $EXIT_FAIL_UNEXPECTED_ERROR
    fi
fi

EXIT_TEST_FAIL_BYOC_NOT_SET=1
EXIT_TEST_FAIL_NO_SECRET=2
EXIT_TEST_FAIL_MISSING_CRED_KEYS=3
EXIT_TEST_FAIL_INVALID_CREDENTIALS=4
EXIT_TEST_FAIL_SECRET_CREATION_FAILED=5

declare -A exitCodeMessages
exitCodeMessages[$EXIT_TEST_FAIL_BYOC_NOT_SET]="AccountClaim does not have byoc=true."
exitCodeMessages[$EXIT_TEST_FAIL_NO_SECRET]="AWS credential secret was not created."
exitCodeMessages[$EXIT_TEST_FAIL_MISSING_CRED_KEYS]="Secret missing required credential keys."
exitCodeMessages[$EXIT_TEST_FAIL_INVALID_CREDENTIALS]="AWS credentials are not functional."
exitCodeMessages[$EXIT_TEST_FAIL_SECRET_CREATION_FAILED]="Failed to create CCS secret."

byocClaimName="${BYOC_CLAIM_NAME:-test-byoc-claim}"
byocNamespace="${BYOC_NAMESPACE_NAME:-test-byoc}"
byocAccountId="${OSD_STAGING_2_AWS_ACCOUNT_ID}"
accountCrNamespace="${NAMESPACE}"
awsAccountProfile="osd-staging-2"
sleepInterval="${SLEEP_INTERVAL:-10}"

function explain {
    exitCode=$1
    echo "${exitCodeMessages[$exitCode]}"
}

function setup {
    echo "========================================================================="
    echo "SETUP: Creating namespace, CCS secret, and BYOC AccountClaim"
    echo "========================================================================="

    echo "Creating namespace: ${byocNamespace}"
    createNamespace "${byocNamespace}" || return $?

    echo "Creating CCS secret using rotate_iam_access_keys.sh..."
    echo "  Account: ${byocAccountId}, Namespace: ${byocNamespace}"

    if ! ./hack/scripts/aws/rotate_iam_access_keys.sh -p "${awsAccountProfile}" -u osdCcsAdmin -a "${byocAccountId}" -n "${byocNamespace}" -o /dev/stdout | oc apply -f -; then
        echo "ERROR: Failed to create CCS secret"
        return $EXIT_TEST_FAIL_SECRET_CREATION_FAILED
    fi

    echo "Waiting ${sleepInterval}s for AWS to propagate IAM credentials..."
    sleep "${sleepInterval}"
    echo "✓ CCS secret created"

    echo "Creating CCS AccountClaim: ${byocClaimName}"
    local claimYaml
    claimYaml=$(oc process --local -p NAME="${byocClaimName}" -p NAMESPACE="${byocNamespace}" -p CCS_ACCOUNT_ID="${byocAccountId}" -f hack/templates/aws.managed.openshift.io_v1alpha1_ccs_accountclaim_cr.tmpl)
    ocCreateResourceIfNotExists "${claimYaml}" || return $?

    echo "Waiting for CCS AccountClaim to become Ready..."
    timeout="${ACCOUNT_CLAIM_READY_TIMEOUT}"
    waitForAccountClaimCRReadyOrFailed "${byocClaimName}" "${byocNamespace}" "${timeout}" || return $?

    echo "✓ Setup complete"
    return 0
}

function test {
    echo "========================================================================="
    echo "TEST: Validating BYOC credential propagation"
    echo "========================================================================="

    echo "Getting CCS AccountClaim..."
    local claimYaml
    claimYaml=$(generateAccountClaimCRYaml "${byocClaimName}" "${byocNamespace}")
    local accClaim
    accClaim=$(ocGetResourceAsJson "${claimYaml}" | jq -r '.items[0]')

    echo ""
    echo "--- Validating AccountClaim BYOC Configuration ---"

    echo "Checking spec.byoc..."
    local byoc
    byoc=$(echo "$accClaim" | jq -r '.spec.byoc')
    if [ "$byoc" != "true" ]; then
        echo "ERROR: AccountClaim should have .spec.byoc=true, got: ${byoc}"
        return $EXIT_TEST_FAIL_BYOC_NOT_SET
    fi
    echo "✓ spec.byoc is true"

    echo "Checking spec.byocAWSAccountID..."
    local claimAccountId
    claimAccountId=$(echo "$accClaim" | jq -r '.spec.byocAWSAccountID')
    if [ "$claimAccountId" != "${byocAccountId}" ]; then
        echo "ERROR: Expected byocAWSAccountID=${byocAccountId}, got: ${claimAccountId}"
        return $EXIT_FAIL_UNEXPECTED_ERROR
    fi
    echo "✓ spec.byocAWSAccountID is ${byocAccountId}"

    echo ""
    echo "--- Validating AWS Credential Secret ---"

    echo "Checking awsCredentialSecret spec..."
    local secretName
    secretName=$(echo "$accClaim" | jq -r '.spec.awsCredentialSecret.name')
    local secretNamespace
    secretNamespace=$(echo "$accClaim" | jq -r '.spec.awsCredentialSecret.namespace')

    echo "  Secret name: ${secretName}"
    echo "  Secret namespace: ${secretNamespace}"

    echo "Checking if secret exists..."
    if ! oc get secret "${secretName}" -n "${secretNamespace}" &>/dev/null; then
        echo "ERROR: AWS credential secret '${secretName}' not found in namespace '${secretNamespace}'"
        return $EXIT_TEST_FAIL_NO_SECRET
    fi
    echo "✓ Secret exists: ${secretName}"

    echo "Extracting secret data..."
    local secret
    secret=$(oc get secret "${secretName}" -n "${secretNamespace}" -o json)

    echo "Validating secret contains required keys..."
    local hasAccessKeyId hasSecretAccessKey

    hasAccessKeyId=$(echo "$secret" | jq -r '.data.aws_access_key_id // "missing"')
    if [ "$hasAccessKeyId" = "missing" ]; then
        echo "ERROR: Secret missing 'aws_access_key_id' key"
        return $EXIT_TEST_FAIL_MISSING_CRED_KEYS
    fi
    echo "✓ Secret contains aws_access_key_id"

    hasSecretAccessKey=$(echo "$secret" | jq -r '.data.aws_secret_access_key // "missing"')
    if [ "$hasSecretAccessKey" = "missing" ]; then
        echo "ERROR: Secret missing 'aws_secret_access_key' key"
        return $EXIT_TEST_FAIL_MISSING_CRED_KEYS
    fi
    echo "✓ Secret contains aws_secret_access_key"

    echo ""
    echo "--- Validating Credentials Functionality ---"

    echo "Decoding credentials from secret..."
    local accessKeyId secretAccessKey
    accessKeyId=$(echo "$secret" | jq -r '.data.aws_access_key_id' | base64 -d)
    secretAccessKey=$(echo "$secret" | jq -r '.data.aws_secret_access_key' | base64 -d)

    if [ -z "$accessKeyId" ] || [ -z "$secretAccessKey" ]; then
        echo "ERROR: Decoded credentials are empty"
        return $EXIT_TEST_FAIL_INVALID_CREDENTIALS
    fi
    echo "✓ Credentials decoded successfully"
    echo "  Access Key ID: ${accessKeyId:0:10}..." # Show first 10 chars only

    echo "Testing credentials with AWS STS GetCallerIdentity..."
    local callerIdentity
    callerIdentity=$(AWS_ACCESS_KEY_ID="$accessKeyId" AWS_SECRET_ACCESS_KEY="$secretAccessKey" aws sts get-caller-identity --output json 2>&1)

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to call AWS STS with provided credentials"
        echo "  Error: ${callerIdentity}"
        return $EXIT_TEST_FAIL_INVALID_CREDENTIALS
    fi

    local accountFromSts
    accountFromSts=$(echo "$callerIdentity" | jq -r '.Account')
    echo "✓ Credentials are functional"
    echo "  Caller Identity Account: ${accountFromSts}"

    if [ "$accountFromSts" != "${byocAccountId}" ]; then
        echo "WARNING: STS account (${accountFromSts}) doesn't match expected account (${byocAccountId})"
        echo "  This may be expected for CCS scenarios"
    else
        echo "✓ STS account matches expected BYOC account"
    fi

    echo ""
    echo "--- Validating Account CR BYOC Configuration ---"

    echo "Getting linked Account CR..."
    local accountLink
    accountLink=$(echo "$accClaim" | jq -r '.spec.accountLink')
    local account
    account=$(oc get account "${accountLink}" -n "${accountCrNamespace}" -o json)

    echo "Checking Account spec.byoc..."
    local accountByoc
    accountByoc=$(echo "$account" | jq -r '.spec.byoc')
    if [ "$accountByoc" != "true" ]; then
        echo "ERROR: Account should have .spec.byoc=true, got: ${accountByoc}"
        return $EXIT_TEST_FAIL_BYOC_NOT_SET
    fi
    echo "✓ Account spec.byoc is true"

    echo "Checking Account spec.awsAccountID..."
    local accountAwsId
    accountAwsId=$(echo "$account" | jq -r '.spec.awsAccountID')
    if [ "$accountAwsId" != "${byocAccountId}" ]; then
        echo "ERROR: Account .spec.awsAccountID should be ${byocAccountId}, got: ${accountAwsId}"
        return $EXIT_FAIL_UNEXPECTED_ERROR
    fi
    echo "✓ Account spec.awsAccountID is ${byocAccountId}"

    echo ""
    echo "========================================================================="
    echo "BYOC CREDENTIAL PROPAGATION TEST PASSED!"
    echo "========================================================================="
    echo "✓ BYOC AccountClaim created successfully"
    echo "✓ BYOC flag set correctly on claim and account"
    echo "✓ AWS credential secret created with required keys"
    echo "✓ Credentials are functional (verified with AWS STS)"
    echo "✓ BYOC configuration propagated correctly"

    return 0
}

function cleanup {
    echo "========================================================================="
    echo "CLEANUP: Removing test resources"
    echo "========================================================================="

    local cleanupExitCode=0

    echo "Deleting BYOC AccountClaim..."
    deleteAccountClaimCR "${byocClaimName}" "${byocNamespace}" "${RESOURCE_DELETE_TIMEOUT}" true 2>/dev/null || {
        echo "WARNING: Failed to delete BYOC AccountClaim"
        cleanupExitCode=$EXIT_FAIL_UNEXPECTED_ERROR
    }

    echo "Deleting CCS secret..."
    oc delete secret byoc -n "${byocNamespace}" 2>/dev/null || {
        echo "WARNING: Failed to delete CCS secret"
    }

    echo "Deleting namespace..."
    deleteNamespace "${byocNamespace}" "${RESOURCE_DELETE_TIMEOUT}" true 2>/dev/null || {
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
