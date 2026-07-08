# Apache Ignite 2.18.0 — Kubernetes 배포 가이드

## 개요

| 항목 | 값 |
|---|---|
| 버전 | 2.18.0 |
| 이미지 | `apacheignite/ignite:2.18.0` |
| 네임스페이스 | `ignite` |
| 구성 | 단일 노드 StatefulSet |
| 설정 형식 | Spring XML (`ignite-config.xml`) |
| 저장소 | `csi-cinder-sc-retain` 10Gi PVC |

## 파일 구성

```
ignite/
├── ignite-config.xml   # Ignite 노드 설정 (Spring XML) — 참조용 원본
└── ignite.yaml         # Namespace, ConfigMap, Services, StatefulSet 전체
```

> `ignite.yaml`의 ConfigMap에 `ignite-config.xml` 내용이 인라인으로 포함된다.
> 설정 변경 시 두 파일을 동시에 수정하여 동기화 유지.

## 아키텍처

### 버전 선택 이유: Ignite 2.18.0 vs 3.x

| | Ignite 2.18.0 | Ignite 3.x |
|---|---|---|
| Trino 481 연동 | ✅ `jdbc:ignite:thin://` 지원 | ❌ 미지원 (다른 JDBC 드라이버) |
| 설정 방식 | Spring XML | HOCON |
| 클러스터 초기화 | 자동 (init 불필요) | 수동 REST API 초기화 필요 |
| 이미지 | `apacheignite/ignite:2.18.0` | `apache/ignite3:3.x` |
| Docker Hub | `apacheignite/` 네임스페이스 | `apache/` 네임스페이스 |

### 포트

| 포트 | 프로토콜 | 용도 |
|---|---|---|
| 47500 | TCP | 노드 간 Discovery (TcpDiscoverySpi) |
| 47100 | TCP | 노드 간 통신 (TcpCommunicationSpi) |
| 10800 | TCP | JDBC Thin Client (Trino 연결 포트) |

### 서비스

| 이름 | 타입 | 용도 |
|---|---|---|
| `ignite-svc-headless` | ClusterIP (None) | 노드 간 peer discovery, DNS 기반 주소 |
| `ignite-svc` | ClusterIP | Trino 등 클라이언트 JDBC 접근 |

### Trino → Ignite 연결 경로

```
Trino Pod (trino 네임스페이스)
  └─ JDBC thin client
       └─ ignite-svc.ignite.svc.cluster.local:10800
            └─ ignite-cluster-0 Pod (ignite 네임스페이스)
```

## 배포

```bash
kubectl apply -f ignite/ignite.yaml

# Pod Ready 대기
until kubectl get pod -n ignite ignite-cluster-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; do sleep 3; done
kubectl get pod -n ignite
```

Ignite 2.x는 **클러스터 초기화(init) 없이** 노드 기동 시 자동으로 클러스터를 형성한다.

## 검증

```bash
# 노드 상태 확인
kubectl logs -n ignite ignite-cluster-0 | grep "Topology snapshot"
# 예상 출력: Topology snapshot [ver=1, servers=1, ...]

# Trino CLI에서 연결 확인
COORD=$(kubectl get pod -n trino -l component=coordinator --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n trino $COORD -- trino --execute "SHOW SCHEMAS FROM ignite;"
# 예상 출력: "information_schema" / "public"
```

## SQL 테스트

Trino CLI에서 실행:
```sql
-- 테이블 생성 (primary_key 필수)
CREATE TABLE ignite.public.test_sql (
  id    INTEGER,
  name  VARCHAR,
  score DOUBLE
) WITH (primary_key = ARRAY['id']);

-- 데이터 삽입
INSERT INTO ignite.public.test_sql VALUES (1, 'alice', 95.5), (2, 'bob', 87.0);

-- 조회
SELECT * FROM ignite.public.test_sql ORDER BY id;
```

> Ignite 2.x에서 Trino로 테이블 생성 시 반드시 `WITH (primary_key = ARRAY['컬럼명'])` 지정 필요.

## 설정 변경 적용

```bash
# ignite-config.xml 수정 후 ignite.yaml의 ConfigMap도 동일하게 수정
kubectl apply -f ignite/ignite.yaml
kubectl rollout restart statefulset/ignite-cluster -n ignite
```

## 삭제

```bash
# StatefulSet과 서비스만 삭제 (PVC는 retain 정책으로 유지됨)
kubectl delete -f ignite/ignite.yaml

# PVC까지 완전 삭제 (데이터 소실 주의)
kubectl delete pvc work-ignite-cluster-0 -n ignite
```

## 향후 계획 (Helm 전환 시)

- `replicas` → `values.yaml` 파라미터화
- `storageClassName`, `storage` 크기 → values 분리
- `ignite-config.xml` → Helm 템플릿(`templates/configmap.yaml`)으로 이동
- Trino가 Ignite 3 지원 추가 시: 이미지를 `apache/ignite3:3.x`로 교체, HOCON 설정으로 전환
