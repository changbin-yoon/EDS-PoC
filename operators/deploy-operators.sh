#!/usr/bin/env bash
# 세 오퍼레이터(Spark, Kafka, CNPG)를 각각의 네임스페이스에 배포하고
# Prometheus ServiceMonitor / PodMonitor를 활성화한다.
# 실행 전: kubectl context가 올바른 클러스터를 가리키는지 확인할 것.
set -euo pipefail

# values 파일을 상대 경로로 참조하므로 항상 스크립트 위치에서 실행
cd "$(dirname "$0")"

# ─── Helm repo 등록 ────────────────────────────────────────────────
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo add strimzi         https://strimzi.io/charts/
helm repo add cnpg            https://cloudnative-pg.github.io/charts
helm repo update

# ─── 네임스페이스 생성 (이미 존재하면 무시) ──────────────────────
for ns in operator-spark operator-kafka operator-cnpg; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ─── 1. Spark Operator ─────────────────────────────────────────────
helm upgrade --install spark-operator spark-operator/spark-operator \
  -f spark-operator-values.yaml \
  -n operator-spark

# ─── 2. Strimzi Kafka Operator ─────────────────────────────────────
helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  -f kafka-operator-values.yaml \
  -n operator-kafka

# ─── 3. CloudNativePG Operator ─────────────────────────────────────
# 안전 교체 순서: 새 오퍼레이터를 먼저 띄운 뒤 기존 것을 제거한다.
# 이렇게 해야 오퍼레이터 공백 시간 없이 n8n PostgreSQL 관리가 유지됨.
#
# Step A: 새 오퍼레이터 설치 (CRD는 기존 것을 그대로 사용)
helm upgrade --install cnpg cnpg/cloudnative-pg \
  -f cnpg-operator-values.yaml \
  -n operator-cnpg \
  --set crds.create=false

# Step B: 새 오퍼레이터 기동 확인
kubectl rollout status deployment -n operator-cnpg --timeout=120s

# Step C: 기존 오퍼레이터 제거 (이미 새 오퍼레이터가 떠 있으므로 공백 없음)
if helm status cnpg -n cnpg-system &>/dev/null; then
  echo "기존 cnpg-system 오퍼레이터 제거 중..."
  helm uninstall cnpg -n cnpg-system
fi

echo ""
echo "=== 배포 완료 ==="
echo "ServiceMonitor / PodMonitor 확인:"
kubectl get servicemonitor,podmonitor -A | grep -E "operator-spark|operator-kafka|operator-cnpg" || true
