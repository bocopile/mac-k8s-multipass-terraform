#!/bin/bash
set -euo pipefail

# Usage: addons/verify.sh [addon-names...]
# Verify addon installation status

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${GENERATED_DIR}"
  exit 1
fi

# Addon별 검증 설정
declare -A ADDON_CHECK=(
    # Format: "context:namespace:deployment|statefulset|daemonset:name"
    # priority-classes: cluster-scoped 리소스이므로 verify.sh에서 별도 확인
    ["cilium"]="mgmt:kube-system:daemonset:cilium"
    ["tetragon"]="mgmt:kube-system:daemonset:tetragon"
    ["metallb"]="mgmt:metallb-system:deployment:metallb-controller"
    ["cert-manager"]="mgmt:cert-manager:deployment:cert-manager"
    ["vault"]="mgmt:vault:statefulset:vault"
    ["eso"]="mgmt:security:deployment:external-secrets"
    ["argocd"]="mgmt:argocd:deployment:argocd-server"
    ["k8sgpt"]="mgmt:k8sgpt:deployment:k8sgpt-operator-controller-manager"
    ["thanos"]="mgmt:observability:statefulset:thanos-receive"
    ["prometheus-stack"]="mgmt:monitoring:statefulset:prometheus-kube-prometheus-stack-prometheus"
    ["alloy"]="mgmt:observability:daemonset:alloy"
    ["alloy-app1"]="app1:observability:daemonset:alloy"

    ["loki"]="mgmt:observability:statefulset:loki"
    ["tempo"]="mgmt:observability:deployment:tempo"
    ["istio"]="mgmt:istio-system:deployment:istiod"
    ["kiali"]="mgmt:istio-system:deployment:kiali"
    ["kyverno"]="app1:security:deployment:kyverno-admission-controller"
    ["falco"]="app1:security:daemonset:falco"
    ["holmesgpt"]="mgmt:aiops:deployment:robusta-runner"
    ["botkube"]="mgmt:aiops:deployment:botkube"
    ["minio"]="mgmt:backup:statefulset:minio"
    ["velero"]="mgmt:backup:deployment:velero"
)

usage() {
    cat <<EOF
사용법: $(basename "$0") [addon-names...]

옵션:
    --all               모든 addon 검증
    --summary           요약만 출력
    -h, --help          도움말 출력

예시:
    # 모든 addon 검증
    $(basename "$0") --all

    # 특정 addon만 검증
    $(basename "$0") vault argocd prometheus-stack

    # 요약 출력
    $(basename "$0") --all --summary

Available addons:
$(list_addons)
EOF
}

list_addons() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for addon in "${!ADDON_CHECK[@]}"; do
        echo "  - $addon"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

verify_addon() {
    local addon=$1
    local check_config="${ADDON_CHECK[$addon]:-}"

    if [[ -z "$check_config" ]]; then
        echo "  ⚠️  $addon - No verification config defined"
        return 2
    fi

    IFS=':' read -r context namespace kind name <<< "$check_config"
    local kube_context="kubernetes-admin@${context}"

    # 네임스페이스 확인
    if ! kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" get namespace "$namespace" &>/dev/null; then
        echo "  ❌ $addon - Namespace not found: $namespace"
        return 1
    fi

    # 리소스 확인
    local ready=false
    case "$kind" in
        deployment)
            if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                -n "$namespace" get deployment "$name" &>/dev/null; then
                local replicas_ready
                local replicas_desired
                replicas_ready=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get deployment "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                replicas_desired=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get deployment "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

                if [[ "$replicas_ready" == "$replicas_desired" ]] && [[ "$replicas_ready" -gt 0 ]]; then
                    ready=true
                fi
            fi
            ;;
        statefulset)
            if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                -n "$namespace" get statefulset "$name" &>/dev/null; then
                local replicas_ready
                local replicas_desired
                replicas_ready=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get statefulset "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                replicas_desired=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get statefulset "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

                if [[ "$replicas_ready" == "$replicas_desired" ]] && [[ "$replicas_ready" -gt 0 ]]; then
                    ready=true
                fi
            fi
            ;;
        daemonset)
            if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                -n "$namespace" get daemonset "$name" &>/dev/null; then
                local number_ready
                local desired_number
                number_ready=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get daemonset "$name" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
                desired_number=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get daemonset "$name" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "1")

                if [[ "$number_ready" == "$desired_number" ]] && [[ "$number_ready" -gt 0 ]]; then
                    ready=true
                fi
            fi
            ;;
    esac

    if $ready; then
        echo "  ✅ $addon - Running ($kind/$name in $namespace @ $context)"
        return 0
    else
        echo "  ❌ $addon - Not ready ($kind/$name in $namespace @ $context)"
        return 1
    fi
}

# 아키텍처 불변 조건(Contract) 검증
# C2: Grafana Alloy WAL 버퍼, C4: Kyverno app only, NetworkPolicy, PriorityClass
verify_contracts() {
    local passed=0
    local failed=0

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Architecture Contract Verification"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # C2: Grafana Alloy가 전 클러스터에 배포되어 있는지 (메트릭/로그 수집 보장)
    echo ""
    echo "  [C2] Grafana Alloy DaemonSet (전 클러스터 수집 에이전트)"
    for ctx in mgmt app1; do
        local kctx="kubernetes-admin@${ctx}"
        if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kctx" \
            -n observability get daemonset alloy &>/dev/null 2>&1; then
            echo "    ✅ ${ctx}: alloy DaemonSet 존재"
            ((passed++)) || true
        else
            echo "    ❌ ${ctx}: alloy DaemonSet 없음 (메트릭/로그 수집 불가)"
            ((failed++)) || true
        fi
    done

    # C4: Kyverno가 mgmt에는 없고 app 클러스터에만 있는지
    echo ""
    echo "  [C4] Kyverno app 클러스터 전용 (mgmt 제외)"
    if ! kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "kubernetes-admin@mgmt" \
        -n security get deployment kyverno-admission-controller &>/dev/null 2>&1; then
        echo "    ✅ mgmt: Kyverno 없음 (정상)"
        ((passed++)) || true
    else
        echo "    ❌ mgmt: Kyverno가 mgmt에 설치됨 (ADR-003 위반)"
        ((failed++)) || true
    fi
    for ctx in app1; do
        local kctx="kubernetes-admin@${ctx}"
        if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kctx" \
            -n security get deployment kyverno-admission-controller &>/dev/null 2>&1; then
            echo "    ✅ ${ctx}: Kyverno 존재"
            ((passed++)) || true
        else
            echo "    ⚠️  ${ctx}: Kyverno 없음"
            ((failed++)) || true
        fi
    done

    # PriorityClass 검증: platform-critical, platform-normal 존재 여부
    echo ""
    echo "  [인프라] PriorityClass (platform-critical / platform-normal)"
    for ctx in mgmt app1; do
        local kctx="kubernetes-admin@${ctx}"
        local pc_ok=true
        for pc in platform-critical platform-normal; do
            if ! kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kctx" \
                get priorityclass "$pc" &>/dev/null 2>&1; then
                echo "    ❌ ${ctx}: PriorityClass '${pc}' 없음"
                pc_ok=false
                ((failed++)) || true
            fi
        done
        if $pc_ok; then
            echo "    ✅ ${ctx}: platform-critical + platform-normal 존재"
            ((passed++)) || true
        fi
    done

    # NetworkPolicy 검증: 플랫폼 네임스페이스에 default-deny-all 적용 여부
    echo ""
    echo "  [보안] NetworkPolicy default-deny-all (플랫폼 네임스페이스)"
    for ctx in mgmt app1; do
        local kctx="kubernetes-admin@${ctx}"
        for ns in monitoring security; do
            if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kctx" \
                -n "$ns" get networkpolicy default-deny-all &>/dev/null 2>&1; then
                echo "    ✅ ${ctx}/${ns}: default-deny-all 존재"
                ((passed++)) || true
            else
                echo "    ❌ ${ctx}/${ns}: default-deny-all 없음 (Zero-Trust 미적용)"
                ((failed++)) || true
            fi
        done
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Contract Summary: passed=$passed, failed=$failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return $failed
}

main() {
    local addons_to_verify=()

    local run_contracts=false

    # 인자 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                addons_to_verify=("${!ADDON_CHECK[@]}")
                run_contracts=true
                shift
                ;;
            --summary)
                shift
                ;;
            --list)
                list_addons
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "ERROR: Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                addons_to_verify+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#addons_to_verify[@]} -eq 0 ]]; then
        echo "ERROR: No addons specified"
        usage
        exit 1
    fi

    # 검증 실행
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Addon Verification"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local total=0
    local success=0
    local failed=0
    local skipped=0

    for addon in "${addons_to_verify[@]}"; do
        ((total++)) || true
        verify_addon "$addon"
        local ret=$?
        case $ret in
            0) ((success++)) || true ;;
            2) ((skipped++)) || true ;;
            *) ((failed++)) || true ;;
        esac
    done

    # 결과 출력
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Verification Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Total:   $total"
    echo "  Success: $success"
    echo "  Failed:  $failed"
    echo "  Skipped: $skipped"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # --all 시 아키텍처 Contract 검증 추가 실행
    local contract_failed=0
    if $run_contracts; then
        verify_contracts || contract_failed=$?
    fi

    if [[ $failed -gt 0 || $contract_failed -gt 0 ]]; then
        echo "❌ Some addons are not ready or contracts are violated"
        exit 1
    else
        echo "✅ All verified addons are running"
        exit 0
    fi
}

main "$@"
