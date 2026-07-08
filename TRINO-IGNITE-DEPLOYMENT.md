# Trino + Apache Ignite on Kubernetes — 배포 절차서

> 작성일: 2026-07-08  
> 버전: Trino 481 / Apache Ignite 2.18.0  
> 클러스터: `dev-cluster.k8s.miribit.lab`

---

## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [파일 구조](#2-파일-구조)
3. [사전 요구사항](#3-사전-요구사항)
4. [배포 절차](#4-배포-절차)
5. [연동 검증](#5-연동-검증)
6. [운영 명령어](#6-운영-명령어)
7. [주요 설정 참조](#7-주요-설정-참조)
8. [트러블슈팅](#8-트러블슈팅)
9. [향후 계획](#9-향후-계획)

---

## 1. 아키텍처 개요

```
┌─────────────────────────────────────────────────────────┐
│  Namespace: trino                                        │
│                                                          │
│  ┌─────────────────────────────────────┐                │
│  │  trino-coordinator (Deployment, 1)  │                │
│  │  trinodb/trino:481                  │                │
│  │  단일 노드 모드 (coordinator+worker) │                │
│  │  :8080 (HTTP/UI/JDBC)              │                │
│  └──────────────┬──────────────────────┘                │
│                 │ Ingress (nginx)                        │
│  trino.dev-cluster.k8s.miribit.lab                      │
└─────────────────┼───────────────────────────────────────┘
                  │ jdbc:ignite:thin://
                  │ ignite-svc.ignite.svc.cluster.local:10800
┌─────────────────┼───────────────────────────────────────┐
│  Namespace: ignite                                       │
│                 │                                        │
│  ┌──────────────▼──────────────────────┐                │
│  │  ignite-cluster-0 (StatefulSet, 1)  │                │
│  │  apacheignite/ignite:2.18.0         │                │
│  │  :47500 (discovery)                 │                │
│  │  :47100 (communication)             │                │
│  │  :10800 (JDBC thin client)          │                │
│  └────────────────────────────────────-┘                │
│                                                          │
│  PVC: work-ignite-cluster-0 (10Gi, csi-cinder-sc-retain)│
└─────────────────────────────────────────────────────────┘
```

### 버전 선택 근거

**Ignite 2.18.0 선택 이유**
Trino 481의 내장 Ignite 플러그인은 Ignite **2.x JDBC 드라이버**(`jdbc:ignite:thin://`)를 번들한다.
Ignite 3.x는 완전히 다른 JDBC 프로토콜(`jdbc:ignite3://`)을 사용하므로
Trino 481과 Ignite 3.x는 현재 연동 불가 — Trino 측에서 Ignite 3 지원 추가 시 전환 예정.

**Trino 단일 노드 모드**
`node-scheduler.include-coordinator=true` 설정으로 Worker Pod 없이 Coordinator 1개만 운영.
개발 환경 메모리 절감 목적. 프로덕션 확장 시 Worker Deployment 별도 추가.

---

## 2. 파일 구조

```
kubernetes/
├── ignite/
│   ├── ignite-config.xml        # Ignite 노드 설정 (Spring XML) — 참조용 원본
│   ├── ignite.yaml              # K8s 전체 리소스 (Namespace~StatefulSet)
│   └── README.md                # Ignite 개별 가이드
├── trino/
│   ├── trino.yaml               # K8s 전체 리소스 (Namespace~Ingress)
│   └── README.md                # Trino 개별 가이드
└── TRINO-IGNITE-DEPLOYMENT.md   # 이 문서 (통합 배포 절차서)
```

---

## 3. 사전 요구사항

| 항목 | 요구사항 |
|---|---|
| Kubernetes | 1.20 이상 |
| StorageClass | `csi-cinder-sc-retain` (Ignite PVC용) |
| IngressClass | `nginx` (`trino.dev-cluster.k8s.miribit.lab` 라우팅) |
| DNS | `*.dev-cluster.k8s.miribit.lab` 와일드카드 등록 완료 |
| Docker Hub | `apacheignite/ignite:2.18.0`, `trinodb/trino:481` 접근 가능 |

> **Docker Hub 이미지 확인**  
> `apacheignite/ignite` 네임스페이스와 `apache/ignite3` 네임스페이스는 별개.  
> Ignite 2.x → `apacheignite/ignite:<version>`  
> Ignite 3.x → `apache/ignite3:<version>`

---

## 4. 배포 절차

### 4-1. Ignite 배포

```bash
kubectl apply -f ignite/ignite.yaml
```

**Ready 확인 (최대 2분)**
```bash
until kubectl get pod -n ignite ignite-cluster-0 \
  -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true
do sleep 3; done
kubectl get pod -n ignite
```

**정상 기동 로그 확인**
```bash
kubectl logs -n ignite ignite-cluster-0 | grep "Topology snapshot"
# 예상: Topology snapshot [ver=1, servers=1, ...]
```

> Ignite 2.x는 별도 클러스터 초기화(init) 불필요. 노드 기동 시 자동으로 클러스터 형성.

---

### 4-2. Trino 배포

```bash
kubectl apply -f trino/trino.yaml
```

**Ready 확인**
```bash
until kubectl get pod -n trino -l component=coordinator \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true
do sleep 3; done
kubectl get pod -n trino
```

**기동 로그 확인**
```bash
kubectl logs -n trino -l component=coordinator | grep "SERVER STARTED\|Added catalog"
# 예상:
# -- Added catalog ignite using connector ignite --
# ======== SERVER STARTED ========
```

---

### 4-3. 전체 상태 확인

```bash
kubectl get pods -n ignite -n trino
# 또는
kubectl get pods --all-namespaces | grep -E "ignite|trino"
```

---

## 5. 연동 검증

### 5-1. Trino → Ignite 기본 연결

```bash
COORD=$(kubectl get pod -n trino -l component=coordinator \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n trino $COORD -- trino --execute "SHOW CATALOGS;"
# ignite 카탈로그 목록에 있어야 함

kubectl exec -n trino $COORD -- trino --execute "SHOW SCHEMAS FROM ignite;"
# "information_schema" / "public" 출력되어야 함
```

### 5-2. SQL 전체 흐름 테스트

```bash
COORD=$(kubectl get pod -n trino -l component=coordinator \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

# 테이블 생성
kubectl exec -n trino $COORD -- trino --execute "
CREATE TABLE ignite.public.test_sql (
  id    INTEGER,
  name  VARCHAR,
  score DOUBLE
) WITH (primary_key = ARRAY['id']);"

# 데이터 삽입
kubectl exec -n trino $COORD -- trino --execute "
INSERT INTO ignite.public.test_sql VALUES
  (1, 'alice', 95.5),
  (2, 'bob',   87.0),
  (3, 'charlie', 92.3);"

# 조회
kubectl exec -n trino $COORD -- trino --execute "
SELECT * FROM ignite.public.test_sql ORDER BY id;"
```

**기대 출력**
```
"1","alice","95.5"
"2","bob","87.0"
"3","charlie","92.3"
```

### 5-3. Trino UI 접속

브라우저에서 `http://trino.dev-cluster.k8s.miribit.lab` 접속.  
(인증 없음 — 기본 설정 기준)

---

## 6. 운영 명령어

### Ignite

```bash
# Pod 로그 실시간 확인
kubectl logs -f -n ignite ignite-cluster-0

# 설정 변경 후 재시작 (ignite.yaml 수정 후)
kubectl apply -f ignite/ignite.yaml
kubectl rollout restart statefulset/ignite-cluster -n ignite

# Ignite CLI (Pod 내부)
kubectl exec -it -n ignite ignite-cluster-0 -- bash
# Pod 내: /opt/ignite/bin/ignite.sh

# Ignite 삭제 (PVC는 retain)
kubectl delete -f ignite/ignite.yaml

# PVC 포함 완전 삭제 (데이터 소실 주의)
kubectl delete pvc work-ignite-cluster-0 -n ignite
```

### Trino

```bash
# Pod 로그 실시간 확인
kubectl logs -f -n trino -l component=coordinator

# 설정 변경 후 재시작 (trino.yaml 수정 후)
kubectl apply -f trino/trino.yaml
kubectl rollout restart deployment/trino-coordinator -n trino

# Trino CLI 접속
COORD=$(kubectl get pod -n trino -l component=coordinator \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n trino $COORD -- trino

# Trino 삭제
kubectl delete -f trino/trino.yaml
```

### 전체 재배포 순서

```bash
# 1. Ignite 먼저 배포 (Trino가 연결 대상이므로)
kubectl apply -f ignite/ignite.yaml
# Ignite Ready 대기 ...

# 2. Trino 배포
kubectl apply -f trino/trino.yaml
# Trino Ready 대기 ...

# 3. 연동 확인
COORD=$(kubectl get pod -n trino -l component=coordinator \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n trino $COORD -- trino --execute "SHOW SCHEMAS FROM ignite;"
```

---

## 7. 주요 설정 참조

### Ignite 설정 (`ignite/ignite-config.xml`)

| 설정 항목 | 값 | 비고 |
|---|---|---|
| `igniteInstanceName` | `ignite-cluster` | 노드 식별자 |
| `TcpDiscoverySpi.localPort` | `47500` | 디스커버리 포트 |
| `TcpDiscoveryVmIpFinder.addresses` | `ignite-svc-headless:47500..47509` | K8s 헤드리스 서비스 |
| `TcpCommunicationSpi.localPort` | `47100` | 통신 포트 |
| `ClientConnectorConfiguration.port` | `10800` | JDBC thin client 포트 |
| `workDirectory` | `/opt/ignite/work` | 데이터 저장 경로 (PVC 마운트) |

### Trino 설정 (`trino/trino.yaml` ConfigMap)

| 파일 | 항목 | 값 | 비고 |
|---|---|---|---|
| `config.properties` | `coordinator` | `true` | |
| `config.properties` | `node-scheduler.include-coordinator` | `true` | 단일 노드 모드 핵심 설정 |
| `config.properties` | `query.max-memory` | `1GB` | 전체 쿼리 메모리 |
| `config.properties` | `query.max-memory-per-node` | `512MB` | 노드당 쿼리 메모리 |
| `jvm.config` | `-XX:MaxRAMPercentage` | `80` | 컨테이너 메모리 80% = ~1.6Gi heap |
| `ignite.properties` | `connector.name` | `ignite` | |
| `ignite.properties` | `connection-url` | `jdbc:ignite:thin://ignite-svc.ignite.svc.cluster.local:10800` | Ignite 2.x thin JDBC |
| `ignite.properties` | `connection-user` | `eds` | |
| `ignite.properties` | `connection-password` | `edsuser123` | |

### 리소스 할당

| 컴포넌트 | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|
| Ignite | 500m | 2 | 1Gi | 2Gi |
| Trino Coordinator | 500m | 2 | 1Gi | 2Gi |

---

## 8. 트러블슈팅

### 8-1. Ignite Pod ImagePullBackOff

**증상**: `apacheignite/ignite3:3.1.0` 또는 `apache/ignite:3.1.0` 이미지 pull 실패

**원인과 해결**

| 시도한 이미지 | 결과 | 비고 |
|---|---|---|
| `apacheignite/ignite3:3.1.0` | ❌ 실패 | repo 없음 |
| `apache/ignite:3.1.0` | ❌ 실패 | repo 없음 |
| `apache/ignite3:3.1.0` | ✅ 성공 | Ignite 3.x 공식 이미지 |
| `apacheignite/ignite:2.18.0` | ✅ 성공 | Ignite 2.x 공식 이미지 |

**결론**: Docker Hub 네임스페이스 규칙
- Ignite 2.x → `apacheignite/ignite`
- Ignite 3.x → `apache/ignite3` (Apache 공식 org)

---

### 8-2. Trino CrashLoopBackOff — JVM 오류

**증상**: `Unrecognized VM option 'GCLockerRetryAllocationCount=32'`

**원인**: Trino 481은 Java 25에서 실행. `GCLockerRetryAllocationCount` 플래그는 Java 21에서 제거됨.

**해결**: `jvm.config`에서 해당 플래그 제거.

```
# 제거
-XX:GCLockerRetryAllocationCount=32
```

---

### 8-3. Trino CrashLoopBackOff — Defunct 설정

**증상**: `Defunct property 'query.max-total-memory-per-node'`

**원인**: Trino 481에서 해당 설정이 제거됨.

**해결**: `config.properties`에서 제거.
```
# 제거
query.max-total-memory-per-node=...
```

---

### 8-4. Trino Ignite 카탈로그 로드 실패 — Java 모듈 오류

**증상**: `InaccessibleObjectException: Unable to make field long java.nio.Buffer.address accessible`

**원인**: Ignite JDBC 드라이버가 Java 모듈 시스템의 `java.nio` 내부 필드에 리플렉션으로 접근 시도. Java 9+ 모듈 시스템에서 차단됨.

**해결**: `jvm.config`에 `--add-opens` 추가.
```
--add-opens=java.base/java.nio=ALL-UNNAMED
--add-opens=java.base/sun.nio.ch=ALL-UNNAMED
--add-opens=java.base/java.lang=ALL-UNNAMED
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED
```

---

### 8-5. Trino → Ignite 3 JDBC 연결 실패

**증상**: `JDBC URL for Ignite connector should start with jdbc:ignite:thin://`

**원인**: Trino 481의 Ignite 플러그인은 Ignite **2.x** JDBC 드라이버를 번들. Ignite 3.x JDBC(`jdbc:ignite3://`)는 완전히 다른 드라이버이므로 연동 불가.

**해결**: Ignite 2.x(`apacheignite/ignite:2.18.0`)로 전환. URL을 `jdbc:ignite:thin://`으로 설정.

---

### 8-6. Ignite 연결 타임아웃

**증상**: Trino에서 Ignite 연결 실패 (`Failed to connect to server`)

**원인 및 확인**:
```bash
# Ignite Pod가 Ready 상태인지 확인
kubectl get pod -n ignite ignite-cluster-0

# 10800 포트 리스닝 확인 (로그에서)
kubectl logs -n ignite ignite-cluster-0 | grep "10800"
# 예상: TCP:10800 이 LocalPorts에 포함되어야 함
```

**해결**: Ignite Pod가 `1/1 Running` 상태가 된 후 Trino에서 재시도.

---

## 9. 향후 계획

### Helm 차트 전환

각 서비스를 독립 Helm 차트로 관리:

```
charts/
├── ignite/           # Ignite Helm 차트
│   ├── Chart.yaml
│   ├── values.yaml   # 버전, 리소스, 포트 파라미터화
│   └── templates/
│       ├── configmap.yaml
│       ├── statefulset.yaml
│       └── service.yaml
└── trino/            # Trino Helm 차트
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── configmap-config.yaml
        ├── configmap-catalog.yaml
        ├── deployment.yaml
        ├── service.yaml
        └── ingress.yaml
```

### Ignite 3.x 전환 조건

Trino가 Ignite 3 지원을 추가하면:
1. `ignite/ignite.yaml` 이미지: `apacheignite/ignite:2.18.0` → `apache/ignite3:<버전>`
2. `ignite/ignite-config.xml` → `ignite/ignite-config.conf` (HOCON 형식으로 교체)
3. Ignite 클러스터 초기화 Job 재추가 (3.x는 init 필요)
4. `trino/trino.yaml` 카탈로그: `jdbc:ignite:thin://` → `jdbc:ignite3://`

### 보안 강화

현재 Ignite는 인증 없이 운영 중. 인증 추가 시:

```xml
<!-- ignite-config.xml에 추가 -->
<property name="authenticationEnabled" value="true"/>
```

Trino 카탈로그의 `connection-user`/`connection-password`를 K8s Secret으로 분리:
```yaml
# Secret으로 분리 예시
apiVersion: v1
kind: Secret
metadata:
  name: ignite-credentials
  namespace: trino
stringData:
  username: eds
  password: edsuser123
```
