#!/bin/bash
set -euo pipefail

# =============================================================================
# 인프라 구축 완료 후 전체 검증 스크립트
# Usage: bash scripts/verify-infra.sh
#
# Phase 1: VM & K8s 노드
# Phase 2: Addon 설치 상태 (Helm)
# Phase 3: Pod 상태
# Phase 4: 네트워크 (Cross-Cluster LB, Istio Gateway 도메인)
# Phase 5: Observability (Prometheus targets, Loki 로그, Grafana)
# Phase 6: Backup (Velero BSL)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${KUBECONFIG_MULTI}"
  echo "  Run 'tofu apply' first."
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_MULTI}"

PASS=0
FAIL=0
WARN=0

pass()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn()  { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

CLUSTERS="mgmt app1"

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 1: VM & K8s Nodes"
echo "================================================================="

echo ""
echo "--- 1-1. Multipass VMs ---"
VM_RUNNING=$(multipass list 2>/dev/null | grep -c Running || true)
EXPECTED_VMS=4
if [[ "${VM_RUNNING}" -ge ${EXPECTED_VMS} ]]; then
  pass "All ${VM_RUNNING} VMs Running"
else
  fail "Only ${VM_RUNNING}/${EXPECTED_VMS} VMs Running"
fi

echo ""
echo "--- 1-2. Kubernetes Nodes ---"
for CTX in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CTX}"
  NODE_INFO=$(kubectl --context "${CONTEXT}" get nodes --no-headers 2>/dev/null || true)
  if [[ -z "${NODE_INFO}" ]]; then
    fail "${CTX}: cannot connect to cluster"
    continue
  fi
  TOTAL=$(echo "${NODE_INFO}" | wc -l | tr -d ' ')
  READY=$(echo "${NODE_INFO}" | grep -c " Ready" || true)
  if [[ "${READY}" -eq "${TOTAL}" ]]; then
    pass "${CTX}: ${READY}/${TOTAL} nodes Ready"
  else
    fail "${CTX}: ${READY}/${TOTAL} nodes Ready"
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 2: Addon Installation (Helm)"
echo "================================================================="

for CTX in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CTX}"
  DEPLOYED=$(helm --kube-context "${CONTEXT}" list -A --no-headers 2>/dev/null | grep -c deployed || true)
  FAILED_LIST=$(helm --kube-context "${CONTEXT}" list -A --no-headers 2>/dev/null | grep failed || true)
  FAILED_COUNT=$(echo "${FAILED_LIST}" | grep -c failed 2>/dev/null || true)

  if [[ "${FAILED_COUNT}" -eq 0 ]]; then
    pass "${CTX}: ${DEPLOYED} releases deployed"
  else
    warn "${CTX}: ${DEPLOYED} deployed, ${FAILED_COUNT} failed"
    echo "${FAILED_LIST}" | while read -r line; do
      NAME=$(echo "${line}" | awk '{print $1}')
      NS=$(echo "${line}" | awk '{print $2}')
      echo "         -> ${NAME} (${NS})"
    done
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 3: Pod Health"
echo "================================================================="

for CTX in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CTX}"
  BAD_PODS=$(kubectl --context "${CONTEXT}" get pods -A --no-headers 2>/dev/null \
    | grep -v -E "Running|Completed|ContainerCreating" || true)
  BAD_COUNT=$(echo "${BAD_PODS}" | grep -c -v "^$" 2>/dev/null || true)

  if [[ "${BAD_COUNT}" -eq 0 ]]; then
    pass "${CTX}: All pods healthy"
  else
    warn "${CTX}: ${BAD_COUNT} unhealthy pod(s)"
    echo "${BAD_PODS}" | head -5 | while read -r line; do
      echo "         -> ${line}"
    done
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 4: Network"
echo "================================================================="

# 4-1. MetalLB LoadBalancer IPs
echo ""
echo "--- 4-1. LoadBalancer Services (mgmt) ---"
LB_SVCS=$(kubectl --context "kubernetes-admin@mgmt" get svc -A \
  --field-selector spec.type=LoadBalancer \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IP:.status.loadBalancer.ingress[0].ip' \
  --no-headers 2>/dev/null || true)

if [[ -n "${LB_SVCS}" ]]; then
  LB_COUNT=$(echo "${LB_SVCS}" | wc -l | tr -d ' ')
  NO_IP=$(echo "${LB_SVCS}" | grep -c "<none>" || true)
  if [[ "${NO_IP}" -eq 0 ]]; then
    pass "${LB_COUNT} LB services, all have External IPs"
  else
    warn "${LB_COUNT} LB services, ${NO_IP} without External IP"
  fi
  echo "${LB_SVCS}" | while read -r line; do echo "         ${line}"; done
else
  warn "No LoadBalancer services found"
fi

# 4-2. Cross-Cluster connectivity (via mgmt pod)
echo ""
echo "--- 4-2. Cross-Cluster Connectivity ---"

# LB IP 파일에서 읽기
LOKI_LB=$(cat "${GENERATED_DIR}/loki-lb-ip" 2>/dev/null || true)
THANOS_LB=$(kubectl --context "kubernetes-admin@mgmt" -n observability get svc thanos-receive \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
MINIO_LB=$(cat "${GENERATED_DIR}/minio-ip" 2>/dev/null || true)

if [[ -n "${LOKI_LB}" ]] && [[ -n "${THANOS_LB}" ]] && [[ -n "${MINIO_LB}" ]]; then
  CONN_RESULT=$(kubectl --context "kubernetes-admin@mgmt" run verify-net \
    --image=busybox:1.36 --rm -i --restart=Never --quiet 2>/dev/null -- sh -c "
    PASS=0; FAIL=0
    wget -qO- --timeout=3 http://${LOKI_LB}:3100/ready >/dev/null 2>&1 && PASS=\$((PASS+1)) || FAIL=\$((FAIL+1))
    wget -qO- --timeout=3 http://${THANOS_LB}:10902/-/ready >/dev/null 2>&1 && PASS=\$((PASS+1)) || FAIL=\$((FAIL+1))
    wget -qO- --timeout=3 http://${MINIO_LB}:9000/minio/health/live >/dev/null 2>&1 && PASS=\$((PASS+1)) || FAIL=\$((FAIL+1))
    echo \"\${PASS}/3\"
  " 2>/dev/null || echo "0/3")

  if [[ "${CONN_RESULT}" == "3/3" ]]; then
    pass "Pod -> LB connectivity: Loki, Thanos, MinIO all reachable"
  else
    warn "Pod -> LB connectivity: ${CONN_RESULT} reachable"
  fi
else
  warn "LB IPs not fully resolved (Loki=${LOKI_LB:-?}, Thanos=${THANOS_LB:-?}, MinIO=${MINIO_LB:-?})"
fi

# 4-3. Alloy endpoint IP 일치 확인
echo ""
echo "--- 4-3. Alloy Endpoint IP Consistency ---"
for CTX in app1; do
  ALLOY_CM=$(kubectl --context "kubernetes-admin@${CTX}" -n observability get cm alloy \
    -o jsonpath='{.data}' 2>/dev/null || true)

  if [[ -z "${ALLOY_CM}" ]]; then
    warn "${CTX}: Alloy ConfigMap not found"
    continue
  fi

  # Thanos remote_write IP
  ALLOY_THANOS=$(echo "${ALLOY_CM}" | grep -o 'http://[0-9.]*:19291' | head -1 || true)
  EXPECTED_THANOS="http://${THANOS_LB}:19291"
  if [[ "${ALLOY_THANOS}" == "${EXPECTED_THANOS}" ]]; then
    pass "${CTX}: Alloy -> Thanos IP matches (${ALLOY_THANOS})"
  elif [[ -z "${ALLOY_THANOS}" ]]; then
    warn "${CTX}: No Thanos remote_write in Alloy config"
  else
    fail "${CTX}: Alloy Thanos IP mismatch (config=${ALLOY_THANOS}, actual=${EXPECTED_THANOS})"
  fi

  # Loki push URL IP
  ALLOY_LOKI=$(echo "${ALLOY_CM}" | grep -o 'http://[0-9.]*:3100' | head -1 || true)
  EXPECTED_LOKI="http://${LOKI_LB}:3100"
  if [[ "${ALLOY_LOKI}" == "${EXPECTED_LOKI}" ]]; then
    pass "${CTX}: Alloy -> Loki IP matches (${ALLOY_LOKI})"
  elif [[ -z "${ALLOY_LOKI}" ]]; then
    warn "${CTX}: No Loki URL in Alloy config (using in-cluster?)"
  else
    fail "${CTX}: Alloy Loki IP mismatch (config=${ALLOY_LOKI}, actual=${EXPECTED_LOKI})"
  fi
done

# 4-4. Istio Gateway 도메인 접근
echo ""
echo "--- 4-4. Domain Access (Istio Gateway) ---"
INGRESS_IP=$(kubectl --context "kubernetes-admin@mgmt" -n istio-system \
  get svc istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -z "${INGRESS_IP}" ]]; then
  warn "Istio Ingress Gateway not found or no IP assigned"
else
  DOMAIN_LIST="grafana.bocopile.io prometheus.bocopile.io alertmanager.bocopile.io argocd.bocopile.io vault.bocopile.io minio.bocopile.io thanos.bocopile.io opencost.bocopile.io"
  DOMAIN_PASS=0
  DOMAIN_FAIL=0
  for DOMAIN in ${DOMAIN_LIST}; do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 \
      -H "Host: ${DOMAIN}" "http://${INGRESS_IP}/" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" =~ ^(200|301|302|303|307)$ ]]; then
      DOMAIN_PASS=$((DOMAIN_PASS + 1))
    else
      DOMAIN_FAIL=$((DOMAIN_FAIL + 1))
      echo "         [FAIL] ${DOMAIN} -> HTTP ${HTTP_CODE}"
    fi
  done

  DOMAIN_TOTAL=$((DOMAIN_PASS + DOMAIN_FAIL))
  if [[ "${DOMAIN_FAIL}" -eq 0 ]]; then
    pass "All ${DOMAIN_TOTAL} domains accessible via Istio Gateway (${INGRESS_IP})"
  else
    warn "${DOMAIN_PASS}/${DOMAIN_TOTAL} domains accessible (${DOMAIN_FAIL} failed)"
  fi
fi

# 4-5. /etc/hosts 확인
echo ""
echo "--- 4-5. /etc/hosts ---"
HOSTS_COUNT=$(grep -c 'bocopile\.io' /etc/hosts 2>/dev/null || true)
if [[ "${HOSTS_COUNT}" -gt 0 ]]; then
  pass "/etc/hosts has ${HOSTS_COUNT} bocopile.io entries"
else
  warn "/etc/hosts has no bocopile.io entries (run: sudo bash scripts/update-hosts-bocopile.sh)"
fi

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 5: Observability"
echo "================================================================="

# 5-1. Prometheus targets
echo ""
echo "--- 5-1. Prometheus Targets ---"
TARGETS_JSON=$(kubectl --context "kubernetes-admin@mgmt" -n monitoring \
  exec svc/kube-prometheus-stack-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null || true)

if [[ -n "${TARGETS_JSON}" ]]; then
  read -r UP DOWN < <(echo "${TARGETS_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
up = sum(1 for t in d["data"]["activeTargets"] if t["health"] == "up")
down = sum(1 for t in d["data"]["activeTargets"] if t["health"] != "up")
print(f"{up} {down}")
' 2>/dev/null || echo "0 0")

  if [[ "${DOWN}" -eq 0 ]]; then
    pass "Prometheus: ${UP} targets up, 0 down"
  else
    warn "Prometheus: ${UP} up, ${DOWN} down"
    echo "${TARGETS_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
for t in d["data"]["activeTargets"]:
    if t["health"] != "up":
        job = t["labels"].get("job", "?")
        err = t.get("lastError", "")[:80]
        print(f"         -> {job}: {err}")
' 2>/dev/null || true
  fi
else
  fail "Cannot reach Prometheus API"
fi

# 5-2. Loki 로그 수집
echo ""
echo "--- 5-2. Loki Log Ingestion ---"
LOKI_CLUSTERS=$(kubectl --context "kubernetes-admin@mgmt" run verify-loki \
  --image=busybox:1.36 --rm -i --restart=Never --quiet 2>/dev/null -- \
  wget -qO- 'http://loki.observability.svc.cluster.local:3100/loki/api/v1/label/cluster/values' 2>/dev/null || true)

if [[ -n "${LOKI_CLUSTERS}" ]]; then
  CLUSTER_LIST=$(echo "${LOKI_CLUSTERS}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print(",".join(d.get("data", [])))
' 2>/dev/null || echo "")

  EXPECTED="app1,mgmt"
  if [[ "${CLUSTER_LIST}" == *"mgmt"* ]] && [[ "${CLUSTER_LIST}" == *"app1"* ]]; then
    pass "Loki receiving logs from all clusters: ${CLUSTER_LIST}"
  elif [[ -n "${CLUSTER_LIST}" ]]; then
    warn "Loki receiving logs from: ${CLUSTER_LIST} (expected: mgmt,app1)"
  else
    warn "Loki has no cluster labels"
  fi
else
  warn "Cannot query Loki cluster labels"
fi

# 5-3. Grafana datasources & dashboards
echo ""
echo "--- 5-3. Grafana ---"
GRAFANA_READY=$(kubectl --context "kubernetes-admin@mgmt" -n monitoring \
  get deploy kube-prometheus-stack-grafana --no-headers 2>/dev/null | awk '{print $2}')
DS_COUNT=$(kubectl --context "kubernetes-admin@mgmt" -n monitoring \
  get cm -l grafana_datasource=1 --no-headers 2>/dev/null | wc -l | tr -d ' ')
DASH_COUNT=$(kubectl --context "kubernetes-admin@mgmt" -n monitoring \
  get cm -l grafana_dashboard=1 --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "${GRAFANA_READY}" == "1/1" ]]; then
  pass "Grafana ready, ${DS_COUNT} datasources, ${DASH_COUNT} dashboards"
else
  fail "Grafana not ready (${GRAFANA_READY:-not found})"
fi

# 5-4. Thanos
echo ""
echo "--- 5-4. Thanos ---"
THANOS_QUERY=$(kubectl --context "kubernetes-admin@mgmt" -n observability \
  get deploy thanos-query --no-headers 2>/dev/null | awk '{print $2}')
THANOS_RECEIVE=$(kubectl --context "kubernetes-admin@mgmt" -n observability \
  get sts thanos-receive --no-headers 2>/dev/null | awk '{print $2}')

if [[ "${THANOS_QUERY}" == "1/1" ]] && [[ -n "${THANOS_RECEIVE}" ]]; then
  pass "Thanos Query (${THANOS_QUERY}) + Receive (${THANOS_RECEIVE})"
else
  fail "Thanos not ready (query=${THANOS_QUERY:-?}, receive=${THANOS_RECEIVE:-?})"
fi

# 5-5. Alloy DaemonSet
echo ""
echo "--- 5-5. Alloy ---"
for CTX in ${CLUSTERS}; do
  ALLOY_DS=$(kubectl --context "kubernetes-admin@${CTX}" -n observability \
    get ds alloy --no-headers 2>/dev/null || true)
  if [[ -z "${ALLOY_DS}" ]]; then
    fail "${CTX}: Alloy DaemonSet not found"
    continue
  fi
  DESIRED=$(echo "${ALLOY_DS}" | awk '{print $2}')
  READY=$(echo "${ALLOY_DS}" | awk '{print $4}')
  if [[ "${DESIRED}" == "${READY}" ]]; then
    pass "${CTX}: Alloy ${READY}/${DESIRED} ready"
  else
    warn "${CTX}: Alloy ${READY}/${DESIRED} ready"
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 6: Backup"
echo "================================================================="

# 6-1. MinIO
echo ""
echo "--- 6-1. MinIO ---"
MINIO_READY=$(kubectl --context "kubernetes-admin@mgmt" -n backup \
  get deploy minio --no-headers 2>/dev/null | awk '{print $2}')
if [[ "${MINIO_READY}" == "1/1" ]]; then
  pass "MinIO ready (LB: ${MINIO_LB:-?})"
else
  fail "MinIO not ready (${MINIO_READY:-not found})"
fi

# 6-2. Velero BSL
echo ""
echo "--- 6-2. Velero BSL ---"
for CTX in ${CLUSTERS}; do
  VELERO_READY=$(kubectl --context "kubernetes-admin@${CTX}" -n backup \
    get deploy velero --no-headers 2>/dev/null | awk '{print $2}')
  BSL_PHASE=$(kubectl --context "kubernetes-admin@${CTX}" -n backup \
    get bsl default -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")

  if [[ "${VELERO_READY}" != "1/1" ]]; then
    fail "${CTX}: Velero not ready (${VELERO_READY:-not found})"
  elif [[ "${BSL_PHASE}" == "Available" ]]; then
    pass "${CTX}: Velero ready, BSL Available"
  else
    warn "${CTX}: Velero ready, BSL ${BSL_PHASE}"
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 7: Security & GitOps"
echo "================================================================="

# 7-1. Vault
echo ""
echo "--- 7-1. Vault ---"
VAULT_STS=$(kubectl --context "kubernetes-admin@mgmt" -n vault \
  get sts vault --no-headers 2>/dev/null | awk '{print $2}')
if [[ -n "${VAULT_STS}" ]]; then
  pass "Vault StatefulSet ${VAULT_STS}"
else
  fail "Vault not found"
fi

# 7-2. ArgoCD
echo ""
echo "--- 7-2. ArgoCD ---"
ARGOCD_READY=$(kubectl --context "kubernetes-admin@mgmt" -n argocd \
  get deploy argocd-server --no-headers 2>/dev/null | awk '{print $2}')
if [[ "${ARGOCD_READY}" == "1/1" ]]; then
  pass "ArgoCD server ready"
else
  fail "ArgoCD not ready (${ARGOCD_READY:-not found})"
fi

# 7-3. Kyverno
echo ""
echo "--- 7-3. Kyverno ---"
for CTX in app1; do
  KYVERNO=$(kubectl --context "kubernetes-admin@${CTX}" -n security \
    get deploy kyverno-admission-controller --no-headers 2>/dev/null | awk '{print $2}')
  if [[ "${KYVERNO}" == "1/1" ]]; then
    pass "${CTX}: Kyverno admission controller ready"
  else
    warn "${CTX}: Kyverno (${KYVERNO:-not found})"
  fi
done

# 7-4. Falco
echo ""
echo "--- 7-4. Falco ---"
for CTX in app1; do
  FALCO_DS=$(kubectl --context "kubernetes-admin@${CTX}" -n security \
    get ds falco --no-headers 2>/dev/null || true)
  if [[ -n "${FALCO_DS}" ]]; then
    DESIRED=$(echo "${FALCO_DS}" | awk '{print $2}')
    READY=$(echo "${FALCO_DS}" | awk '{print $4}')
    if [[ "${DESIRED}" == "${READY}" ]]; then
      pass "${CTX}: Falco ${READY}/${DESIRED} ready"
    else
      warn "${CTX}: Falco ${READY}/${DESIRED} ready"
    fi
  else
    warn "${CTX}: Falco not found"
  fi
done

# 7-5. Istio
echo ""
echo "--- 7-5. Istio ---"
ISTIOD=$(kubectl --context "kubernetes-admin@mgmt" -n istio-system \
  get deploy istiod --no-headers 2>/dev/null | awk '{print $2}')
GATEWAY=$(kubectl --context "kubernetes-admin@mgmt" -n istio-system \
  get deploy istio-ingressgateway --no-headers 2>/dev/null | awk '{print $2}')
if [[ "${ISTIOD}" == "1/1" ]] && [[ "${GATEWAY}" == "1/1" ]]; then
  pass "Istiod (${ISTIOD}) + IngressGateway (${GATEWAY})"
else
  warn "Istio: istiod=${ISTIOD:-?}, gateway=${GATEWAY:-?}"
fi

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL + WARN))
echo ""
echo "================================================================="
echo "  Verification Summary"
echo "================================================================="
echo ""
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  WARN: ${WARN}"
echo "  TOTAL: ${TOTAL}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo "  Result: SOME CHECKS FAILED"
  echo "================================================================="
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo "  Result: ALL PASSED (${WARN} warnings)"
  echo "================================================================="
  exit 0
else
  echo "  Result: ALL CHECKS PASSED"
  echo "================================================================="
  exit 0
fi
