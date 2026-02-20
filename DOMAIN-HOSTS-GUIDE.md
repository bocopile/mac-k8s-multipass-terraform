# Domain & Hosts Configuration Guide

> **Mac 환경에서 VM 접근 및 WebUI 사용 가이드**
>
> Last Updated: 2026-02-20

---

## 📊 서비스 접근 방법 요약

| 접근 방법 | 서비스 수 | /etc/hosts 필요 | 설명 |
|-----------|----------|----------------|------|
| **Port-Forward** | 11개 | ❌ No | localhost로 접근 (개발 환경) |
| **LoadBalancer** | 5개 | ✅ Yes | MetalLB IP로 직접 접근 (운영 환경) |
| **ClusterIP** | 대부분 | ❌ No | 클러스터 내부에서만 접근 |

---

## 🌐 WebUI 서비스 목록

### 1. Port-Forward 방식 (Mac /etc/hosts 불필요)

| 서비스 | Namespace | Port | 접속 URL | 기본 인증 |
|--------|-----------|------|----------|----------|
| **Grafana** | observability | 3000 | http://localhost:3000 | admin / admin |
| **Prometheus** | observability | 9090 | http://localhost:9090 | - |
| **AlertManager** | observability | 9093 | http://localhost:9093 | - |
| **ArgoCD** | argocd | 8080 | https://localhost:8080 | admin / [secret] |
| **Kiali** | istio-system | 20001 | http://localhost:20001/kiali | anonymous |
| **Vault UI** | vault | 8200 | http://localhost:8200 | [root-token] |
| **Tempo** | observability | 3100 | http://localhost:3100 | - |
| **Chaos Mesh** | chaos-mesh | 2333 | http://localhost:2333 | - |
| **Goldilocks** | goldilocks | 8080 | http://localhost:8080 | - |
| **OpenCost** | opencost | 9090 | http://localhost:9090 | - |
| **Thanos Query** | observability | 9090 | http://localhost:9091 | - |

#### 접속 명령어

```bash
# Grafana
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80

# Prometheus
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# AlertManager
kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093

# ArgoCD (HTTPS)
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Kiali
kubectl port-forward -n istio-system svc/kiali 20001:20001

# Vault UI
kubectl port-forward -n vault svc/vault-ui 8200:8200

# Tempo
kubectl port-forward -n observability svc/tempo 3100:3100

# Chaos Mesh
kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333

# Goldilocks
kubectl port-forward -n goldilocks svc/goldilocks-dashboard 8080:80

# OpenCost
kubectl port-forward -n opencost svc/opencost 9090:9090

# Thanos Query
kubectl port-forward -n observability svc/thanos-query 9091:9090
```

---

### 2. LoadBalancer 방식 (Mac /etc/hosts 권장)

| 서비스 | Namespace | Port | LoadBalancer IP 파일 | 용도 |
|--------|-----------|------|---------------------|------|
| **MinIO Console** | backup | 9001 | generated/minio-ip | 객체 스토리지 관리 |
| **MinIO API** | backup | 9000 | generated/minio-ip | S3 호환 API |
| **Vault API** | vault | 8200 | generated/vault-lb-ip | Secret 관리 (ESO용) |
| **Thanos Receive** | observability | 19291 | generated/thanos-receive-ip | 메트릭 수집 |
| **Loki** | observability | 3100 | generated/loki-lb-ip | 로그 수집 |
| **Istio Gateway** | istio-system | 80/443 | (MetalLB 자동 할당) | 앱 Ingress |

#### LoadBalancer IP 확인 방법

```bash
# MinIO IP
cat generated/minio-ip
# 또는
kubectl get svc -n backup minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Vault IP
cat generated/vault-lb-ip
# 또는
kubectl get svc -n vault vault-ui-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Thanos Receive IP
cat generated/thanos-receive-ip
# 또는
kubectl get svc -n observability thanos-receive -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Loki IP
cat generated/loki-lb-ip
# 또는
kubectl get svc -n observability loki-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Istio Gateway IP
kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

---

## 🖥️ Mac /etc/hosts 설정

### 자동 설정 (권장)

프로젝트 루트에서 실행:

```bash
bash scripts/update-hosts-mac.sh
```

이 스크립트는:
1. LoadBalancer IP를 자동으로 조회
2. /etc/hosts에 엔트리 추가 (sudo 필요)
3. 기존 엔트리를 자동으로 업데이트

### 수동 설정

`/etc/hosts` 파일 편집:

```bash
sudo nano /etc/hosts
```

다음 내용 추가:

```bash
# ========================================
# Kubernetes Multi-Cluster Services
# ========================================

# MinIO Object Storage
<MINIO_IP>          minio.local
<MINIO_IP>          s3.local
<MINIO_IP>          minio-console.local

# Vault Secret Management
<VAULT_IP>          vault.local
<VAULT_IP>          vault.mgmt.local

# Thanos Metrics
<THANOS_IP>         thanos.local
<THANOS_IP>         thanos-receive.local

# Loki Logs
<LOKI_IP>           loki.local
<LOKI_IP>           logs.local

# Istio Gateway (선택사항)
<GATEWAY_IP>        gateway.local
<GATEWAY_IP>        api.local
<GATEWAY_IP>        *.app.local

# ========================================
```

**IP 값 치환**:

```bash
# 예시
192.168.205.100     minio.local
192.168.205.100     s3.local
192.168.205.101     vault.local
192.168.205.102     thanos.local
192.168.205.103     loki.local
192.168.205.104     gateway.local
```

---

## 🔐 기본 인증 정보

| 서비스 | Username | Password/Token | 저장 위치 |
|--------|----------|----------------|----------|
| **Grafana** | `admin` | `admin` | 하드코딩 (변경 권장) |
| **ArgoCD** | `admin` | [자동 생성] | `kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| **MinIO** | `minioadmin` | `minioadmin123` | 하드코딩 (변경 필수!) |
| **Vault** | root token | [자동 생성] | `cat generated/vault-root-token` |
| **Kiali** | - | anonymous | 인증 없음 |

### ArgoCD 초기 비밀번호 조회

```bash
kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Vault Root Token 조회

```bash
cat generated/vault-root-token
```

---

## 🔄 VM 간 통신 (Cross-Cluster)

### 통신 흐름

```
app1/app2 → mgmt (LoadBalancer)
    ↓
    ├── Prometheus Agent → Thanos Receive (19291)
    ├── Promtail → Loki (3100)
    ├── External Secrets → Vault (8200)
    └── Velero → MinIO (9000)
```

### 필수 LoadBalancer 서비스

| 서비스 | Source | Destination | 프로토콜 | 목적 |
|--------|--------|-------------|---------|------|
| **Thanos Receive** | app1/app2 | mgmt:19291 | HTTP | 메트릭 집계 |
| **Loki** | app1/app2 | mgmt:3100 | HTTP | 로그 집계 |
| **Vault** | app1/app2 | mgmt:8200 | HTTP | Secret 조회 |
| **MinIO** | app1/app2 | mgmt:9000 | S3 | 백업 저장 |

### Cluster Mesh (Pod-to-Pod)

Cilium ClusterMesh는 자동으로 처리:
- mgmt ↔ app1 ↔ app2 (VXLAN 터널)
- Pod간 직접 통신 가능
- 별도 hosts 설정 불필요

---

## 🚀 빠른 접근 스크립트

### 1. 모든 Port-Forward 한 번에 실행

파일: `scripts/port-forward-all.sh`

```bash
#!/bin/bash

# Background로 모든 port-forward 실행
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80 &
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090 &
kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093 &
kubectl port-forward -n argocd svc/argocd-server 8080:443 &
kubectl port-forward -n istio-system svc/kiali 20001:20001 &
kubectl port-forward -n vault svc/vault-ui 8200:8200 &
kubectl port-forward -n observability svc/tempo 3100:3100 &
kubectl port-forward -n observability svc/thanos-query 9091:9090 &

echo "==================================="
echo "Port-forward started for:"
echo "  Grafana:      http://localhost:3000"
echo "  Prometheus:   http://localhost:9090"
echo "  AlertManager: http://localhost:9093"
echo "  ArgoCD:       https://localhost:8080"
echo "  Kiali:        http://localhost:20001"
echo "  Vault UI:     http://localhost:8200"
echo "  Tempo:        http://localhost:3100"
echo "  Thanos Query: http://localhost:9091"
echo "==================================="
echo ""
echo "Press Ctrl+C to stop all port-forwards"
wait
```

실행:
```bash
bash scripts/port-forward-all.sh
```

### 2. LoadBalancer IP 확인

파일: `scripts/show-loadbalancer-ips.sh`

```bash
#!/bin/bash

echo "========================================="
echo "LoadBalancer IPs"
echo "========================================="

echo ""
echo "MinIO:"
kubectl get svc -n backup minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo ""
echo "  Console: http://$(kubectl get svc -n backup minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9001"
echo "  API:     http://$(kubectl get svc -n backup minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9000"

echo ""
echo "Vault:"
kubectl get svc -n vault vault-ui-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo ""
echo "  UI/API:  http://$(kubectl get svc -n vault vault-ui-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8200"

echo ""
echo "Thanos Receive:"
kubectl get svc -n observability thanos-receive -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo ""
echo "  Endpoint: http://$(kubectl get svc -n observability thanos-receive -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):19291/api/v1/receive"

echo ""
echo "Loki:"
kubectl get svc -n observability loki-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo ""
echo "  Endpoint: http://$(kubectl get svc -n observability loki-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):3100"

echo ""
echo "Istio Gateway:"
kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo ""
echo "  HTTP:  http://$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):80"
echo "  HTTPS: https://$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):443"

echo ""
echo "========================================="
```

실행:
```bash
bash scripts/show-loadbalancer-ips.sh
```

---

## 📝 Istio Gateway 설정 예시

### VirtualService + Gateway 생성

```yaml
# grafana-gateway.yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: grafana-gateway
  namespace: observability
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "grafana.local"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: grafana
  namespace: observability
spec:
  hosts:
    - "grafana.local"
  gateways:
    - grafana-gateway
  http:
    - route:
        - destination:
            host: kube-prometheus-stack-grafana
            port:
              number: 80
```

적용:
```bash
kubectl apply -f grafana-gateway.yaml
```

접속:
```bash
# /etc/hosts에 Istio Gateway IP 추가 후
curl http://grafana.local
```

---

## 🔧 트러블슈팅

### LoadBalancer IP가 할당되지 않음

```bash
# MetalLB 상태 확인
kubectl get pods -n kube-system -l app=metallb

# MetalLB IPAddressPool 확인
kubectl get ipaddresspool -n kube-system

# MetalLB 설정 확인
kubectl get configmap -n kube-system metallb-config -o yaml
```

### Port-forward 연결 실패

```bash
# Pod 상태 확인
kubectl get pods -n <namespace>

# Service 존재 확인
kubectl get svc -n <namespace>

# Logs 확인
kubectl logs -n <namespace> <pod-name>
```

### /etc/hosts 변경이 반영되지 않음

```bash
# DNS 캐시 플러시 (macOS)
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder

# hosts 파일 문법 확인
cat /etc/hosts | grep -v "^#" | grep -v "^$"
```

---

## 📊 접속 우선순위

### 개발/테스트 환경
1. ✅ Port-forward 사용 (localhost)
2. ❌ LoadBalancer 직접 접근 불필요

### 운영/프로덕션 환경
1. ✅ Istio Gateway + VirtualService (도메인 기반)
2. ✅ LoadBalancer IP (/etc/hosts 설정)
3. ⚠️ Port-forward는 디버깅 용도로만

### Cross-Cluster 통신
1. ✅ LoadBalancer 필수 (Thanos, Loki, Vault, MinIO)
2. ✅ Cluster Mesh 자동 처리 (Pod-to-Pod)

---

## 🎯 권장 사항

### 보안
- [ ] Grafana admin 비밀번호 변경
- [ ] MinIO 기본 인증 정보 변경
- [ ] ArgoCD TLS 활성화
- [ ] Vault Root Token 안전하게 보관

### 네트워크
- [ ] /etc/hosts 대신 내부 DNS 서버 구축 (선택사항)
- [ ] Istio Gateway + cert-manager로 HTTPS 설정
- [ ] MetalLB IP Pool 확장 (서비스 증가 시)

### 접근성
- [ ] 자주 사용하는 서비스는 Istio VirtualService 생성
- [ ] Port-forward 자동화 스크립트 활용
- [ ] 팀원에게 접속 정보 공유

---

**Last Updated**: 2026-02-20
**Document Version**: 1.0
