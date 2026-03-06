#!/bin/bash
# =============================================================================
# INFRA-001: Host Environment Prerequisites Check
# TERRAFORM-266 / TASK-001 ~ TASK-006
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1"
  local status="$2"
  local detail="${3:-}"

  if [[ "$status" == "PASS" ]]; then
    echo "  [PASS] $label${detail:+ ($detail)}"
    PASS=$((PASS + 1))
  elif [[ "$status" == "WARN" ]]; then
    echo "  [WARN] $label${detail:+ ($detail)}"
    WARN=$((WARN + 1))
  else
    echo "  [FAIL] $label${detail:+ ($detail)}"
    FAIL=$((FAIL + 1))
  fi
}

version_gte() {
  # Returns 0 if $1 >= $2 (semver comparison)
  printf '%s\n%s' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n -C
}

echo "=================================================="
echo "  INFRA-001: Host Environment Prerequisites Check"
echo "=================================================="
echo ""

# --- TASK-001: Multipass ---
echo "[TASK-001] Multipass"
if command -v multipass &>/dev/null; then
  MP_VER=$(multipass version 2>/dev/null | head -1 | awk '{print $NF}')
  check "multipass installed" "PASS" "v${MP_VER}"
else
  check "multipass installed" "FAIL" "not found - brew install multipass"
fi
echo ""

# --- TASK-002: Terraform >= 1.11.3 ---
echo "[TASK-002] Terraform"
if command -v terraform &>/dev/null; then
  TF_VER=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if version_gte "$TF_VER" "1.11.3"; then
    check "terraform >= 1.11.3" "PASS" "v${TF_VER}"
  else
    check "terraform >= 1.11.3" "FAIL" "v${TF_VER} < 1.11.3"
  fi
else
  check "terraform installed" "FAIL" "not found - brew install terraform"
fi
echo ""

# --- TASK-003: Helm CLI ---
echo "[TASK-003] Helm CLI"
if command -v helm &>/dev/null; then
  HELM_VER=$(helm version --short 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  check "helm installed" "PASS" "v${HELM_VER}"
else
  check "helm installed" "FAIL" "not found - brew install helm"
fi
echo ""

# --- TASK-004: kubectl ---
echo "[TASK-004] kubectl"
if command -v kubectl &>/dev/null; then
  KUBE_VER=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
  check "kubectl installed" "PASS" "${KUBE_VER}"
else
  check "kubectl installed" "FAIL" "not found - brew install kubectl"
fi
echo ""

# --- TASK-005: jq ---
echo "[TASK-005] jq"
if command -v jq &>/dev/null; then
  JQ_VER=$(jq --version 2>/dev/null)
  check "jq installed" "PASS" "${JQ_VER}"
else
  check "jq installed" "FAIL" "not found - brew install jq"
fi
echo ""

# --- TASK-006: Host Resources ---
echo "[TASK-006] Host Resources"

# RAM (macOS: sysctl hw.memsize returns bytes)
TOTAL_RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
TOTAL_RAM_GB=$((TOTAL_RAM_BYTES / 1073741824))
REQ_RAM_GB=24
if [[ $TOTAL_RAM_GB -ge $REQ_RAM_GB ]]; then
  check "RAM >= ${REQ_RAM_GB}GB" "PASS" "${TOTAL_RAM_GB}GB total"
else
  check "RAM >= ${REQ_RAM_GB}GB" "FAIL" "${TOTAL_RAM_GB}GB total (need ${REQ_RAM_GB}GB)"
fi

# Disk (available space on /)
AVAIL_DISK_GB=$(df -g / 2>/dev/null | tail -1 | awk '{print $4}')
REQ_DISK_GB=270
if [[ $AVAIL_DISK_GB -ge $REQ_DISK_GB ]]; then
  check "Disk >= ${REQ_DISK_GB}GB free" "PASS" "${AVAIL_DISK_GB}GB available"
else
  check "Disk >= ${REQ_DISK_GB}GB free" "WARN" "${AVAIL_DISK_GB}GB available (recommended ${REQ_DISK_GB}GB)"
fi

# CPU cores
TOTAL_CPU=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 0)
REQ_CPU=16
if [[ $TOTAL_CPU -ge $REQ_CPU ]]; then
  check "CPU >= ${REQ_CPU} cores" "PASS" "${TOTAL_CPU} cores"
else
  check "CPU >= ${REQ_CPU} cores" "WARN" "${TOTAL_CPU} cores (recommended ${REQ_CPU})"
fi

# Architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
  check "Apple Silicon (ARM64)" "PASS" "$ARCH"
else
  check "Architecture" "WARN" "$ARCH (expected arm64)"
fi
echo ""

# --- Summary ---
TOTAL=$((PASS + FAIL + WARN))
echo "=================================================="
echo "  Summary: ${PASS} PASS / ${FAIL} FAIL / ${WARN} WARN (total ${TOTAL})"
echo "=================================================="

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "  [!] $FAIL check(s) failed. Fix before proceeding to INFRA-002."
  exit 1
else
  echo ""
  echo "  [OK] All prerequisites met. Ready for INFRA-002 (terraform apply)."
  exit 0
fi
