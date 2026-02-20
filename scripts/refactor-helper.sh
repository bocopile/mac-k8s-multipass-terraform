#!/bin/bash
# Helper script to refactor addon installation scripts
# Automatically replaces common patterns with library functions

set -euo pipefail

SCRIPT_FILE="${1:?Usage: refactor-helper.sh <script-file>}"

if [[ ! -f "${SCRIPT_FILE}" ]]; then
  echo "ERROR: File not found: ${SCRIPT_FILE}"
  exit 1
fi

echo "Refactoring ${SCRIPT_FILE}..."

# Backup original
cp "${SCRIPT_FILE}" "${SCRIPT_FILE}.bak"

# Pattern 1: Replace initialization block
perl -i -0pe 's/SCRIPT_DIR="\$\(cd "\$\(dirname "\$0"\)" && pwd\)"\nGENERATED_DIR="\$\{SCRIPT_DIR\}\/\.\.\/generated"\nKUBECONFIG_MULTI="\$\{GENERATED_DIR\}\/kubeconfig-multi"\nCLUSTERS_JSON="\$\{GENERATED_DIR\}\/clusters\.json"\n\nif \[\[ ! -f "\$\{CLUSTERS_JSON\}" \]\]; then\n  echo "ERROR: clusters\.json not found at \$\{CLUSTERS_JSON\}"\n  exit 1\nfi/SCRIPT_DIR="\$\(cd "\$\(dirname "\$0"\)" \&\& pwd\)"\n\n# Load libraries\nsource "\$\{SCRIPT_DIR\}\/\.\.\/\.\.\/scripts\/lib\/common.sh"\nsource "\$\{SCRIPT_DIR\}\/\.\.\/\.\.\/scripts\/lib\/constants.sh"\n\n# Setup\nsetup_common_vars/g' "${SCRIPT_FILE}"

# Pattern 2: Replace context setup for mgmt
perl -i -pe 's/MGMT_CONTEXT="kubernetes-admin\@mgmt"\nKC="--kubeconfig \$\{KUBECONFIG_MULTI\} --kube-context \$\{MGMT_CONTEXT\}"\nKC_KUBECTL="--kubeconfig \$\{KUBECONFIG_MULTI\} --context \$\{MGMT_CONTEXT\}"//g' "${SCRIPT_FILE}"

# Pattern 3: Replace helm repo add
perl -i -pe 's/helm repo add (\w+) (https:\/\/[^\s]+) 2>\/dev\/null \|\| true\nhelm repo update/add_helm_repo "$1" "$2"/g' "${SCRIPT_FILE}"

# Pattern 4: Replace echo "===" with log_info
perl -i -pe 's/echo "=== (.+) ==="/log_info "$1"/g' "${SCRIPT_FILE}"

# Pattern 5: Replace kubectl create namespace
perl -i -pe 's/kubectl \$\{KC_KUBECTL\} create namespace (\w+) 2>\/dev\/null \|\| true/ensure_namespace "$1" "mgmt"/g' "${SCRIPT_FILE}"

echo "Refactoring complete: ${SCRIPT_FILE}"
echo "Backup saved: ${SCRIPT_FILE}.bak"
echo "Review changes and remove backup if satisfied."
