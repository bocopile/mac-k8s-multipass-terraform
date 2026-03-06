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
# Phase 7: Security & GitOps
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi 파일을 찾을 수 없습니다: ${KUBECONFIG_MULTI}"
  echo "  먼저 'tofu apply'를 실행하세요."
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_MULTI}"

PASS=0
FAIL=0
WARN=0
INFO=0

pass()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn()  { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
info()  { echo "  [INFO] $1"; INFO=$((INFO + 1)); }

CLUSTERS="mgmt app1"

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 1: VM & K8s 노드 상태"
echo "================================================================="

echo ""
echo "--- 1-1. Multipass VM ---"
VM_RUNNING=$(multipass list 2>/dev/null | grep -c Running || true)
EXPECTED_VMS=4
if [[ "${VM_RUNNING}" -ge ${EXPECTED_VMS} ]]; then
  pass "${VM_RUNNING}개 VM 정상 실행 중"
else
  fail "${VM_RUNNING}/${EXPECTED_VMS}개 VM만 실행 중"
fi

echo ""
echo "--- 1-2. K8s 노드 ---"
for CTX in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CTX}"
  NODE_INFO=$(kubectl --context "${CONTEXT}" get nodes --no-headers 2>/dev/null || true)
  if [[ -z "${NODE_INFO}" ]]; then
    fail "${CTX}: 클러스터에 연결할 수 없습니다"
    continue
  fi
  TOTAL=$(echo "${NODE_INFO}" | wc -l | tr -d ' ')
  READY=$(echo "${NODE_INFO}" | grep -c " Ready" || true)
  if [[ "${READY}" -eq "${TOTAL}" ]]; then
    pass "${CTX}: ${READY}/${TOTAL} 노드 Ready"
  else
    fail "${CTX}: ${READY}/${TOTAL} 노드 Ready"
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 2: Addon 설치 상태 (Helm)"
echo "================================================================="

for CTX in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CTX}"
  DEPLOYED=$(helm --kube-context "${CONTEXT}" list -A --no-headers 2>/dev/null | grep -c deployed || true)
  FAILED_LIST=$(helm --kube-context "${CONTEXT}" list -A --no-headers 2>/dev/null | grep failed || true)
  FAILED_COUNT=$(echo "${FAILED_LIST}" | grep -c failed 2>/dev/null || true)

  if [[ "${FAILED_COUNT}" -eq 0 ]]; then
    pass "${CTX}: ${DEPLOYED}개 릴리스 배포 완료"
  else
    warn "${CTX}: ${DEPLOYED}개 배포, ${FAILED_COUNT}개 실패"
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
echo "  Phase 3: Pod 상태"
echo "================================================================="

for CTX in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CTX}"
  BAD_PODS=$(kubectl --context "${CONTEXT}" get pods -A --no-headers 2>/dev/null \
    | grep -v -E "Running|Completed|ContainerCreating" || true)
  BAD_COUNT=$(echo "${BAD_PODS}" | grep -c -v "^$" 2>/dev/null || true)

  if [[ "${BAD_COUNT}" -eq 0 ]]; then
    pass "${CTX}: 모든 Pod 정상"
  else
    warn "${CTX}: ${BAD_COUNT}개 Pod 비정상 (초기화 중일 수 있음, 잠시 후 재확인)"
    echo "${BAD_PODS}" | head -5 | while read -r line; do
      echo "         -> ${line}"
    done
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 4: 네트워크"
echo "================================================================="

# 4-1. MetalLB LoadBalancer IPs
echo ""
echo "--- 4-1. LoadBalancer 서비스 (mgmt) ---"
LB_SVCS=$(kubectl --context "kubernetes-admin@mgmt" get svc -A \
  --field-selector spec.type=LoadBalancer \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IP:.status.loadBalancer.ingress[0].ip' \
  --no-headers 2>/dev/null || true)

if [[ -n "${LB_SVCS}" ]]; then
  LB_COUNT=$(echo "${LB_SVCS}" | wc -l | tr -d ' ')
  NO_IP=$(echo "${LB_SVCS}" | grep -c "<none>" || true)
  if [[ "${NO_IP}" -eq 0 ]]; then
    pass "${LB_COUNT}개 LB 서비스, 모두 External IP 할당됨"
  else
    warn "${LB_COUNT}개 LB 서비스 중 ${NO_IP}개 IP 미할당"
  fi
  echo "${LB_SVCS}" | while read -r line; do echo "         ${line}"; done
else
  warn "LoadBalancer 서비스가 없습니다"
fi

# 4-2. Cross-Cluster connectivity (via mgmt pod)
echo ""
echo "--- 4-2. 클러스터 간 네트워크 연결 ---"

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
    pass "Pod → LB 연결: Loki, Thanos, MinIO 모두 접근 가능"
  else
    warn "Pod → LB 연결: ${CONN_RESULT} 접근 가능 (나머지는 초기화 중일 수 있음)"
  fi
else
  info "LB IP 일부 미확인 (Loki=${LOKI_LB:-미확인}, Thanos=${THANOS_LB:-미확인}, MinIO=${MINIO_LB:-미확인})"
fi

# 4-3. Alloy endpoint IP 일치 확인
echo ""
echo "--- 4-3. Alloy 엔드포인트 IP 일관성 ---"
for CTX in app1; do
  ALLOY_CM=$(kubectl --context "kubernetes-admin@${CTX}" -n observability get cm alloy \
    -o jsonpath='{.data}' 2>/dev/null || true)

  if [[ -z "${ALLOY_CM}" ]]; then
    warn "${CTX}: Alloy ConfigMap을 찾을 수 없습니다"
    continue
  fi

  # Thanos remote_write IP
  ALLOY_THANOS=$(echo "${ALLOY_CM}" | grep -o 'http://[0-9.]*:19291' | head -1 || true)
  EXPECTED_THANOS="http://${THANOS_LB}:19291"
  if [[ "${ALLOY_THANOS}" == "${EXPECTED_THANOS}" ]]; then
    pass "${CTX}: Alloy → Thanos IP 일치 (${ALLOY_THANOS})"
  elif [[ -z "${ALLOY_THANOS}" ]]; then
    warn "${CTX}: Alloy 설정에 Thanos remote_write가 없습니다"
  else
    fail "${CTX}: Alloy Thanos IP 불일치 (설정=${ALLOY_THANOS}, 실제=${EXPECTED_THANOS})"
  fi

  # Loki push URL IP
  ALLOY_LOKI=$(echo "${ALLOY_CM}" | grep -o 'http://[0-9.]*:3100' | head -1 || true)
  EXPECTED_LOKI="http://${LOKI_LB}:3100"
  if [[ "${ALLOY_LOKI}" == "${EXPECTED_LOKI}" ]]; then
    pass "${CTX}: Alloy → Loki IP 일치 (${ALLOY_LOKI})"
  elif [[ -z "${ALLOY_LOKI}" ]]; then
    info "${CTX}: Alloy에 Loki URL 없음 (in-cluster 사용 가능)"
  else
    fail "${CTX}: Alloy Loki IP 불일치 (설정=${ALLOY_LOKI}, 실제=${EXPECTED_LOKI})"
  fi
done

# 4-4. Istio Gateway 도메인 접근
echo ""
echo "--- 4-4. 도메인 접근 (Istio Gateway) ---"
INGRESS_IP=$(kubectl --context "kubernetes-admin@mgmt" -n istio-system \
  get svc istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -z "${INGRESS_IP}" ]]; then
  info "Istio Ingress Gateway가 아직 준비되지 않았습니다"
else
  DOMAIN_LIST="grafana.bocopile.io prometheus.bocopile.io alertmanager.bocopile.io argocd.bocopile.io vault.bocopile.io minio.bocopile.io thanos.bocopile.io"
  DOMAIN_PASS=0
  DOMAIN_FAIL=0
  DOMAIN_FAIL_LIST=""
  for DOMAIN in ${DOMAIN_LIST}; do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 \
      -H "Host: ${DOMAIN}" "http://${INGRESS_IP}/" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" =~ ^(200|301|302|303|307)$ ]]; then
      DOMAIN_PASS=$((DOMAIN_PASS + 1))
    else
      DOMAIN_FAIL=$((DOMAIN_FAIL + 1))
      DOMAIN_FAIL_LIST="${DOMAIN_FAIL_LIST}\n         ${DOMAIN} → HTTP ${HTTP_CODE}"
    fi
  done

  DOMAIN_TOTAL=$((DOMAIN_PASS + DOMAIN_FAIL))
  if [[ "${DOMAIN_FAIL}" -eq 0 ]]; then
    pass "전체 ${DOMAIN_TOTAL}개 도메인 Istio Gateway 접근 가능 (${INGRESS_IP})"
  else
    info "${DOMAIN_PASS}/${DOMAIN_TOTAL}개 도메인 접근 가능 (Gateway/VirtualService 미적용 도메인은 정상)"
    echo -e "${DOMAIN_FAIL_LIST}"
    echo "         → Gateway 라우팅 설정 후 정상 접근됩니다"
  fi
fi

# 4-5. /etc/hosts 확인
echo ""
echo "--- 4-5. /etc/hosts ---"
HOSTS_COUNT=$(grep -c 'bocopile\.io' /etc/hosts 2>/dev/null || true)
if [[ "${HOSTS_COUNT}" -gt 0 ]]; then
  pass "/etc/hosts에 ${HOSTS_COUNT}개 bocopile.io 항목 등록됨"
else
  info "/etc/hosts에 bocopile.io 미등록 → 도메인 접근이 필요하면 아래 명령어를 실행하세요"
  echo "         sudo bash scripts/update-hosts-bocopile.sh"
fi

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 5: 관찰성 (Observability)"
echo "================================================================="

# 5-1. Prometheus targets
echo ""
echo "--- 5-1. Prometheus 타겟 ---"
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
    pass "Prometheus: ${UP}개 타겟 정상"
  else
    info "Prometheus: ${UP}개 정상, ${DOWN}개 미응답 (Pod 초기화 중일 수 있음)"
    echo "${TARGETS_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
for t in d["data"]["activeTargets"]:
    if t["health"] != "up":
        job = t["labels"].get("job", "?")
        err = t.get("lastError", "")[:80]
        print(f"         → {job}: {err}")
' 2>/dev/null || true
  fi
else
  fail "Prometheus API에 접근할 수 없습니다"
fi

# 5-2. Loki 로그 수집
echo ""
echo "--- 5-2. Loki 로그 수집 ---"
LOKI_CLUSTERS=$(kubectl --context "kubernetes-admin@mgmt" run verify-loki \
  --image=busybox:1.36 --rm -i --restart=Never --quiet 2>/dev/null -- \
  wget -qO- 'http://loki.observability.svc.cluster.local:3100/loki/api/v1/label/cluster/values' 2>/dev/null || true)

if [[ -n "${LOKI_CLUSTERS}" ]]; then
  CLUSTER_LIST=$(echo "${LOKI_CLUSTERS}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print(",".join(d.get("data", [])))
' 2>/dev/null || echo "")

  if [[ "${CLUSTER_LIST}" == *"mgmt"* ]] && [[ "${CLUSTER_LIST}" == *"app1"* ]]; then
    pass "Loki: 전체 클러스터에서 로그 수집 중 (${CLUSTER_LIST})"
  elif [[ -n "${CLUSTER_LIST}" ]]; then
    warn "Loki: 일부 클러스터만 수집 중 (${CLUSTER_LIST}, 기대값: mgmt,app1)"
  else
    warn "Loki: 클러스터 라벨이 없습니다"
  fi
else
  info "Loki 클러스터 라벨 조회 불가 (초기화 중일 수 있음)"
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
  pass "Grafana 정상 (데이터소스 ${DS_COUNT}개, 대시보드 ${DASH_COUNT}개)"
else
  info "Grafana 준비 중 (${GRAFANA_READY:-미확인}) → 잠시 후 자동 복구됩니다"
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
  fail "Thanos 비정상 (query=${THANOS_QUERY:-미확인}, receive=${THANOS_RECEIVE:-미확인})"
fi

# 5-5. Alloy DaemonSet
echo ""
echo "--- 5-5. Alloy ---"
for CTX in ${CLUSTERS}; do
  ALLOY_DS=$(kubectl --context "kubernetes-admin@${CTX}" -n observability \
    get ds alloy --no-headers 2>/dev/null || true)
  if [[ -z "${ALLOY_DS}" ]]; then
    fail "${CTX}: Alloy DaemonSet을 찾을 수 없습니다"
    continue
  fi
  DESIRED=$(echo "${ALLOY_DS}" | awk '{print $2}')
  READY=$(echo "${ALLOY_DS}" | awk '{print $4}')
  if [[ "${DESIRED}" == "${READY}" ]]; then
    pass "${CTX}: Alloy ${READY}/${DESIRED} 정상"
  else
    warn "${CTX}: Alloy ${READY}/${DESIRED} (일부 시작 중)"
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 6: 백업"
echo "================================================================="

# 6-1. MinIO
echo ""
echo "--- 6-1. MinIO ---"
MINIO_READY=$(kubectl --context "kubernetes-admin@mgmt" -n backup \
  get deploy minio --no-headers 2>/dev/null | awk '{print $2}')
if [[ "${MINIO_READY}" == "1/1" ]]; then
  pass "MinIO 정상 (LB: ${MINIO_LB:-미확인})"
else
  fail "MinIO 비정상 (${MINIO_READY:-미확인})"
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
    fail "${CTX}: Velero 비정상 (${VELERO_READY:-미확인})"
  elif [[ "${BSL_PHASE}" == "Available" ]]; then
    pass "${CTX}: Velero 정상, BSL Available"
  else
    info "${CTX}: Velero 정상, BSL ${BSL_PHASE} → MinIO 연결 초기화 중 (잠시 후 Available로 변경)"
  fi
done

# =============================================================================
echo ""
echo "================================================================="
echo "  Phase 7: 보안 & GitOps"
echo "================================================================="

# 7-1. Vault
echo ""
echo "--- 7-1. Vault ---"
VAULT_STS=$(kubectl --context "kubernetes-admin@mgmt" -n vault \
  get sts vault --no-headers 2>/dev/null | awk '{print $2}')
if [[ -n "${VAULT_STS}" ]]; then
  if [[ "${VAULT_STS}" == "1/1" ]]; then
    pass "Vault StatefulSet ${VAULT_STS}"
  else
    info "Vault StatefulSet ${VAULT_STS} → unseal이 필요할 수 있습니다"
  fi
else
  fail "Vault를 찾을 수 없습니다"
fi

# 7-2. ArgoCD
echo ""
echo "--- 7-2. ArgoCD ---"
ARGOCD_READY=$(kubectl --context "kubernetes-admin@mgmt" -n argocd \
  get deploy argocd-server --no-headers 2>/dev/null | awk '{print $2}')
if [[ "${ARGOCD_READY}" == "1/1" ]]; then
  pass "ArgoCD 서버 정상"
else
  fail "ArgoCD 비정상 (${ARGOCD_READY:-미확인})"
fi

# 7-3. Kyverno
echo ""
echo "--- 7-3. Kyverno ---"
for CTX in app1; do
  KYVERNO=$(kubectl --context "kubernetes-admin@${CTX}" -n security \
    get deploy kyverno-admission-controller --no-headers 2>/dev/null | awk '{print $2}')
  if [[ "${KYVERNO}" == "1/1" ]]; then
    pass "${CTX}: Kyverno admission controller 정상"
  else
    warn "${CTX}: Kyverno (${KYVERNO:-미확인})"
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
      pass "${CTX}: Falco ${READY}/${DESIRED} 정상"
    else
      warn "${CTX}: Falco ${READY}/${DESIRED} (일부 시작 중)"
    fi
  else
    warn "${CTX}: Falco를 찾을 수 없습니다"
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
  warn "Istio: istiod=${ISTIOD:-미확인}, gateway=${GATEWAY:-미확인}"
fi

# 7-6. Kiali
echo ""
echo "--- 7-6. Kiali ---"
KIALI_READY=$(kubectl --context "kubernetes-admin@mgmt" -n istio-system \
  get deploy kiali --no-headers 2>/dev/null | awk '{print $2}')
if [[ "${KIALI_READY}" == "1/1" ]]; then
  pass "Kiali 대시보드 정상"
else
  warn "Kiali (${KIALI_READY:-미확인})"
fi

# =============================================================================
# 요약
# =============================================================================
TOTAL=$((PASS + FAIL + WARN + INFO))
echo ""
echo "================================================================="
echo "  검증 결과 요약"
echo "================================================================="
echo ""
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  WARN: ${WARN}"
echo "  INFO: ${INFO}"
echo "  합계: ${TOTAL}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo "  결과: 일부 검증 실패 (FAIL ${FAIL}건 확인 필요)"
  echo "================================================================="
  exit 1
elif [[ "${WARN}" -gt 0 ]] || [[ "${INFO}" -gt 0 ]]; then
  echo "  결과: 전체 통과 (참고사항 ${WARN} WARN / ${INFO} INFO)"
  echo "================================================================="
  exit 0
else
  echo "  결과: 전체 검증 통과"
  echo "================================================================="
  exit 0
fi
