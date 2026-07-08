# Trino 481 — Kubernetes 배포 가이드

## 개요

| 항목 | 값 |
|---|---|
| 버전 | 481 |
| 이미지 | `trinodb/trino:481` |
| 네임스페이스 | `trino` |
| 실행 모드 | 단일 노드 (Coordinator만, Worker 없음) |
| JVM | Java 25.0.2 (이미지 내장) |
| UI | `http://trino.dev-cluster.k8s.miribit.lab` |

## 파일 구성

```
trino/
└── trino.yaml          # Namespace, ConfigMaps, Service, Deployment, Ingress 전체
```

## 아키텍처 결정 사항

### 단일 노드 모드
`node-scheduler.include-coordinator=true`로 Coordinator가 실행(execution)도 담당한다.
Worker Pod를 별도로 띄우지 않아 메모리를 절반으로 줄인다.
개발/테스트 환경에 적합하며, 프로덕션 확장 시 Worker Deployment를 추가한다.

### JVM 플래그 주의 사항
Trino 481은 Java 25에서 실행된다. 다음 플래그들은 Java 21+ 에서 제거/변경되었다:
- ❌ `-XX:GCLockerRetryAllocationCount=32` — Java 21에서 제거됨, 사용 불가
- ❌ `query.max-total-memory-per-node` — Trino 481에서 Defunct, 사용 불가
- ✅ `--add-opens=java.base/java.nio=ALL-UNNAMED` — Ignite JDBC 드라이버 호환성 필요

### Ignite 카탈로그 연결
Trino 481의 Ignite 플러그인은 **Ignite 2.x JDBC 드라이버**를 번들한다.
- ✅ `jdbc:ignite:thin://host:10800` — Ignite 2.x (동작)
- ❌ `jdbc:ignite3://host:10800` — Ignite 3.x (Trino 481 미지원)

## 포트

| 포트 | 용도 |
|---|---|
| 8080 | HTTP (UI, REST API, JDBC) |

## 배포

```bash
kubectl apply -f trino/trino.yaml
kubectl wait --for=condition=Ready pod -l app=trino -n trino --timeout=120s
```

## 검증

```bash
# Pod 확인
kubectl get pods -n trino

# Trino CLI 접속
COORD=$(kubectl get pod -n trino -l component=coordinator --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n trino $COORD -- trino

# Trino CLI 내부
SHOW CATALOGS;
SHOW SCHEMAS FROM ignite;
SELECT * FROM ignite.public.test_sql;
```

## 삭제

```bash
kubectl delete namespace trino
```

## 설정 변경 적용

ConfigMap 수정 후 반드시 Pod 재시작 필요:
```bash
kubectl apply -f trino/trino.yaml
kubectl rollout restart deployment/trino-coordinator -n trino
```

## 향후 계획 (Helm 전환 시)

- `trino.yaml`의 각 ConfigMap 항목 → `values.yaml` 파라미터화
- `ignite.properties`의 `connection-user`/`connection-password` → Secret으로 분리
- Worker 수 → `replicas` 값으로 조절
- Trino가 Ignite 3 지원 추가 시 `connection-url` → `jdbc:ignite3://...`로 변경
