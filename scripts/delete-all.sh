#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

echo "=== Deleting all cluster VMs ==="

# clusters.json이 있으면 동적으로 VM 이름 추출, 없으면 multipass에서 조회
if [[ -f "${CLUSTERS_JSON}" ]]; then
  mapfile -t VMS < <(jq -r '.[].nodes[]' "${CLUSTERS_JSON}")
else
  echo "WARNING: clusters.json not found, querying multipass directly..."
  mapfile -t VMS < <(multipass list --format json 2>/dev/null | jq -r '.list[].name' || true)
fi

for VM in "${VMS[@]}"; do
  echo "Deleting ${VM}..."
  multipass delete "${VM}" --purge 2>/dev/null || true
done

echo "Purging deleted instances..."
multipass purge 2>/dev/null || true

# 생성된 파일 정리
if [[ -d "${GENERATED_DIR}" ]]; then
  echo "Cleaning generated files..."
  rm -f "${GENERATED_DIR}"/cloud-init-*.yaml
  rm -f "${GENERATED_DIR}"/kubeconfig-*
  rm -f "${GENERATED_DIR}"/join-*.sh
  rm -f "${GENERATED_DIR}"/clusters.json
fi

rm -f ~/kubeconfig-multi

echo "=== All VMs deleted and cleaned up ==="
