# 테스트하면서 알게 된 것들 (카테고리별 정리)

> 숫자/결과는 `docs/test-results-summary.md`, 재현 절차는 `docs/airgap-full-test-runbook.md`.
> 여기서는 **왜 그랬는지, 뭘 배웠는지**만 카테고리별로 정리한다.

---

## 1. 배포/설정 버그 (실제로 겪고 고친 것들)

| 증상 | 원인 | 해결 |
|---|---|---|
| `kubectl apply -f ignite.yaml`은 성공했다는데 재기동하면 다른 설정으로 뜸 | StatefulSet의 `serviceName`이 저장소 파일과 실제 배포본이 어긋나 있으면, `kubectl apply`가 StatefulSet 부분만 조용히 Forbidden 처리됨 — ConfigMap만 바뀌고 Pod는 옛 프로세스로 계속 떠 있다가, 다음 재기동 때가 돼서야 새 설정을 읽고 터짐 | `kubectl get statefulset ... -o yaml`로 실제 `serviceName`이 파일과 일치하는지 항상 먼저 확인. 이 저장소는 이미 일치하도록 고쳐둠 |
| Trino에서 Ignite/Redis/PostgreSQL 쿼리가 전부 406 에러 | nginx-ingress가 `X-Forwarded-For` 헤더를 항상 붙이는데 Trino가 forwarded 헤더를 거부하도록 기본 설정돼 있음 | `config.properties`에 `http-server.process-forwarded=true` 추가 (반영됨) |
| Redis 테이블이 항상 0행으로 조회됨 | `redis.key-prefix-schema-table=true`일 때 실제 키 포맷은 `<tableName>:<key>`인데, `<schemaName>:<tableName>:<key>`로 넣었음 (기존 문서 주석이 틀려있었음) | 키를 `<table>:<pk>` 형식으로 (스크립트가 이미 이렇게 생성) |
| Redis 특정 테이블만 0행 (공백값 포함 컬럼) | HSET 값에 공백이 있는데 quote 없이 넘겨서 인자 파싱이 깨짐 → 필드/값 쌍이 안 맞아 전체 삽입 실패 | `generate-test-data.py`/`generate-synthetic-data.py` 둘 다 공백 포함 값을 자동으로 큰따옴표로 감싸도록 수정 |
| Ignite `CrashLoopBackOff`, `ClassNotFoundException: TcpDiscoveryKubernetesIpFinder` | `ignite-config.xml`이 K8s API 기반 노드 탐색을 쓰는데, 그 모듈(`ignite-kubernetes`)을 클래스패스에 올리는 `OPTION_LIBS` 환경변수가 실제 StatefulSet에는 없었음 | 단일 replica면 K8s API 기반 동적 탐색이 애초에 불필요 — `TcpDiscoveryVmIpFinder`(정적 주소)로 단순화 |
| Ignite 부팅 시 `NotWritablePropertyException: tryStop` | `StopNodeOrHaltFailureHandler`의 `tryStop`은 Ignite 2.18.0에서 생성자 인자로만 설정 가능(setter 없음)인데 Spring XML `<property>`로 주입하려 함 | 기본 생성자로 수정 |
| Ignite persistence를 처음 켰는데 쿼리가 안 됨 (`state=INACTIVE`) | persistence를 새로 켠 시점엔 baseline이 없어 자동 활성화가 안 됨 | `control.sh --activate` 1회 수동 실행 (이후 재기동부터는 자동) |
| Trino coordinator `OOMKilled` (대량 INSERT 중) | 46,216행짜리 테이블을 500행 단위 배치로 INSERT하다 컨테이너 메모리 limit(2Gi) 초과 | limit을 4Gi로 상향, 큰 테이블은 배치 크기를 150행으로 축소 |
| `kubectl cp`/`psql \copy` 실행 시 `Cannot open: Read-only file system` | CNPG postgres 컨테이너는 `/tmp`가 읽기전용(보안 하드닝) | `/controller` 또는 `/var/lib/postgresql/data` 하위처럼 쓰기 가능한 경로 사용 |
| `sqlline.sh`가 `Enter username for jdbc:ignite:thin://...`에서 멈춤(EOF 에러) | 비대화형(exec) 환경에서 자격증명 프롬프트가 뜨는데 입력을 못 받음 | `--connectInteractionMode=notAskCredentials` + `-n`/`-p`(auth 비활성화 상태면 아무 값) 옵션 추가 |

---

## 2. 아키텍처/성능 관련 통찰

### 2-1. Redis를 Trino로 붙이면 원래 강점을 못 쓴다

Trino의 Redis 커넥터는 서버사이드 필터링이 없다 — Redis 서버가 할 수 있는 건 `GET`/`HGETALL`/
`SCAN` 같은 키 단위 조회뿐이라, `WHERE` 조건 평가는 전부 Trino 쪽에서 데이터를 다 받아온 뒤에
처리한다. 그래서:

- **PK 조회조차 느렸다.** `WHERE event_id = 123` 같은 쿼리도, Trino 입장에서 `event_id`는
  그냥 해시 안의 값 필드일 뿐이라 "이 값이 키 이름과 대응된다"는 걸 모른다. 결국 테이블에 속한
  키를 전부 SCAN + HGETALL로 끌어와서 하나씩 값을 확인해야 한다 — 내부적으로는 `COUNT(*)`와
  동일한 풀스캔 작업이고, 마지막에 1건만 남기고 버리는 것뿐이다.
- 데이터가 커질수록 이 스캔 비용이 그대로 늘어나고, Ignite/PostgreSQL과 달리 인덱스를 걸어서
  피할 방법이 Trino 레벨에서는 없다 (구조적 한계, 설정으로 고칠 수 있는 문제가 아님).
- Trino Redis 커넥터는 쓰기 자체를 지원하지 않는다 — 이번 테스트에서 데이터 적재는 항상
  `redis-cli`로 직접 했다.
- 결론: Redis 자체가 느린 게 아니라(직접 client로 붙으면 빠름), **"Trino로 SQL 페더레이션"
  이라는 이번 테스트의 전제가 Redis의 강점(O(1) key-value)과 안 맞는 것.** 그래서 이후
  대량/성능 테스트에서는 제외하고 Ignite/PostgreSQL만 다뤘다.

### 2-2. Ignite 스토리지 오버헤드는 "파티션 수 대비 테이블 개수"가 아니라 "파티션당 행 수"가 변수

112K행을 테이블 10개(각각 파티션 1024개)로 나눠 넣었을 때는 6.4KB/행이라는 터무니없는
수치가 나왔다 — 테이블당 1,000~9,000행을 파티션 1024개에 흩뿌리니 파티션 하나당 겨우
1~9행이라, 거의 빈 파티션의 구조적 오버헤드가 실데이터보다 훨씬 컸던 것.

단일 테이블에 900만 행을 넣었을 때는(같은 파티션 수 1024) 파티션당 ~8,800행으로 늘어나면서
바이트/행이 222B까지 떨어져 PostgreSQL(130B/행)과 비슷한 수준이 됐다. **"파티션 개수"가 문제가
아니라 "파티션 하나가 얼마나 많은 행을 담당하는가"가 진짜 변수였다.**

### 2-3. "인메모리 DB"라는 이름이 항상 빠르다는 뜻은 아니다

- 인메모리는 "서빙 방식"이지 "내구성"과는 별개 개념이다. Redis는 AOF+RDB로 디스크에 영속화되어
  있어서 재기동해도 데이터가 남았고, Ignite는 이 배포에서 처음에 persistence가 꺼져 있어서
  재기동하면 테이블 자체가 사라졌다 — 버그가 아니라 원래 "Kafka hot buffer" 용도로 설계된
  휘발성 캐시 계층이었기 때문.
- 인메모리는 "항상 더 빠르다"는 뜻도 아니다. 900만 행(1.1GB) 규모에서는 PostgreSQL도 OS
  페이지 캐시/`shared_buffers`에 데이터가 올라가면 사실상 인메모리처럼 동작한다 — 이 규모에서
  Ignite의 "인메모리"라는 이름값이 자동으로 우위를 보장하지 않았다. 실제로 GROUP BY에서는
  PostgreSQL이 더 빨랐다.

### 2-4. GROUP BY 역전 현상 — 진단 절차와 진짜 원인

900만 행 첫 측정에서 GROUP BY가 Ignite 12.62s, PostgreSQL 4.81s로 예상과 반대로 나왔다.
"Trino 때문 아니냐"부터 검증했다:

1. **Trino `EXPLAIN`으로 pushdown 여부 확인** — 두 카탈로그 다 GROUP BY 전체가 `TableScan`의
   내부 쿼리 문자열에 통째로 들어가 있었다. Trino는 결과 10행만 받아옴 — 집계는 전혀 안 함.
2. **Ignite에 Trino 없이 직접(sqlline) 같은 쿼리 실행** — 12.62s(Trino 경유) vs 10.88s(직접).
   거의 같음 → **Trino 오버헤드가 아니라 진짜 엔진 문제로 확정.**
3. **Ignite `SYS.CACHES` 조회** — 이 테이블의 `QUERY_PARALLELISM`이 **1**이었다. 파드에 할당된
   CPU limit은 4인데(`nproc`는 8을 보고하지만 이건 cgroup 미인지 값이라 무시), 병렬도가 1로
   생성되어 900만 행을 단일 스레드로 순차 처리하고 있었다.
4. **parallelism=4로 재생성 + 재적재 후 재측정** — 12.62s → 5.89s, **약 2.1배 개선.**
   완벽한 4배가 아닌 건 병합/조율 오버헤드 때문에 자연스러운 현상.
5. parallelism 튜닝 후에도 PostgreSQL이 근소하게 더 빠름(직접 질의 기준 4.32s vs 4.84s) —
   PostgreSQL 쪽도 리소스 limit이 테이블 크기(1.1GB)보다 작다는 별개의 병목이 있어서로 보임
   (4장 튜닝 로드맵 참고).

**교훈**: "왜 느린지" 판단할 때 (1) Trino pushdown 여부를 `EXPLAIN`으로 먼저 확인하고,
(2) 의심 가는 엔진에 직접 붙어서 같은 쿼리를 재보고, (3) 그 엔진의 실제 설정(카탈로그/캐시
메타데이터)을 확인하는 순서로 좁혀나가는 게 효과적이었다. 추측만으로 결론 내리지 않고
매 단계 실측으로 확인.

---

## 3. 운영/복구 관련 통찰

### 3-1. 엔진별 관리 측면 비교

**PostgreSQL (CNPG)** — CloudNativePG 오퍼레이터가 관리해줘서 세 시스템 중 가장 "K8s스럽게"
운영된다. Cluster CRD 하나로 선언적으로 관리되고, 장애 시 오퍼레이터가 자동으로 재기동을
처리한다(재기동 테스트에서 가장 손이 안 갔음). WAL 기반이라 크래시에도 커밋된 데이터는 안전하다는
확신을 가장 크게 가질 수 있는 시스템.

**Redis** — 셋 중 설정이 제일 단순하고 운영 부담이 적다. 다만 `maxmemory 512mb` +
`allkeys-lru`가 걸려 있어서, **재기동과 무관하게 데이터가 늘어나면 오래된 키가 조용히 사라질
수 있다** (eviction, 장애가 아님). Sentinel/Cluster 같은 HA 구성이 없어 단일 인스턴스 자체가
SPOF.

**Ignite** — 셋 중 설정 항목이 가장 많고, 실제로 제일 많이 문제가 났던 시스템(위 1장 표 참고).
운영 난이도가 명백히 제일 높다. 대신 persistence를 제대로 켜두면 성능과 내구성을 동시에 챙길
수 있는 유일한 조합 — 다만 원래 아키텍처 의도(휘발성 hot buffer)와는 다른 용도로 쓰는 셈이니
실제로 이렇게 운영할지는 별도 결정이 필요.

### 3-2. 인메모리 DB에서 데이터가 날아갈 수 있는 일반적인 케이스

**Redis** — persistence 자체를 껐을 때(재기동만으로 전부 소실) / 비정상 종료 시
`appendfsync everysec` 설정이라 최대 1초 분량 유실 가능 / **maxmemory+eviction으로 재기동 없이도
소실** / PVC `reclaimPolicy=Delete`면 PVC 삭제 시 데이터도 삭제 / AOF 파일 손상 시 로드 실패.

**Ignite** — persistence 비활성화 시 100% 소실(이번에 실제로 겪음) / WAL 비활성화면 마지막
체크포인트 이후 변경분 유실 / 체크포인트 간격이 길면 그 사이 데이터가 WAL replay에 의존 /
`partitionLossPolicy`에 따라 일부 파티션 유실 시 전체 캐시 영향.

**PostgreSQL/공통** — `fsync=off`/`synchronous_commit=off` 튜닝 시 크래시 유실 가능(이 배포는
기본값이라 해당 없음) / `persistentVolumeClaimRetentionPolicy`(StatefulSet)나 CNPG의 볼륨 정책에
따라 **리소스 삭제 시 PVC까지 연쇄 삭제**될 수 있음 — Pod 재기동과는 다른 경로라 별도 주의 필요.

### 3-3. 장애 발생 시 복구 절차 요약

- **PostgreSQL**: Pod만 죽었으면 `kubectl delete pod`로 재생성 유도(오퍼레이터가 같은 PVC로
  자동 재생성, WAL replay로 복구). PVC까지 유실되면 백업(3장 참고)에서 복구 — 백업 설정 전에는
  이 경로가 아예 없었던 게 가장 큰 리스크였음(지금은 메움).
- **Redis**: Pod 재기동은 AOF/RDB로 자동 복구, 별도 조치 불필요. 메모리 압박으로 최근 데이터가
  안 보이면 장애가 아니라 eviction일 수 있으니 `INFO stats`의 `evicted_keys` 확인.
- **Ignite**: `CrashLoopBackOff`면 로그부터 확인(설정 문제일 확률 높음, 1장 표 참고).
  persistence 최초 활성화 안 됐으면 `control.sh --activate`. PVC가 살아있으면 데이터도 살아있음
  — 단, persistence가 꺼진 상태로 되돌리면 재기동 시 테이블째 사라지는 게 당연한 결과이니 장애
  대응 전에 현재 persistence 설정부터 확인.

---

## 4. 앞으로 성능을 더 끌어올릴 수 있는 지점

★ = 이미 실측으로 효과가 확인된 항목.

### Ignite

| 항목 | 현재 상태 | 개선 방향 |
|---|---|---|
| ★ `query_parallelism` | 4로 상향, 2.1배 개선 확인 | CPU limit을 늘리면 그만큼 더 올릴 여지 있음 — 반드시 cgroup 기준 실제 할당량으로 맞출 것(`nproc`는 host 값이라 오해 소지) |
| 노드 수 | 1개 (single replica) | 여러 노드로 늘리면 파티션이 노드 간에도 분산돼 `query_parallelism`과 별개로 추가 병렬화 가능 — 아직 안 써본 레버 |
| WAL 모드 | `LOG_ONLY` | `FSYNC`(더 안전, 더 느림)와의 트레이드오프 재검토, 체크포인트 주기(`checkpointFreq`, 현재 180000ms)도 튜닝 대상 |
| 보조 인덱스 | 없음 (PK만) | 자주 필터링하는 컬럼에 인덱스 추가 시 비-PK 필터 쿼리 개선 여지 — 아직 테스트 안 함 |

### PostgreSQL

| 항목 | 현재 상태 | 개선 방향 |
|---|---|---|
| Pod 리소스 limit | cpu 1, memory 1Gi | **테이블 자체(1.1GB)가 이미 메모리 limit보다 큼** — Ignite와 같은 "설정이 데이터 규모를 못 따라간" 패턴. 가장 먼저 늘려볼 항목 |
| `shared_buffers` | 128MB (기본값) | 리소스 limit 상향과 같이 올릴 것 — 지금은 테이블 전체를 캐시에 못 올림 |
| `work_mem` | 4MB (기본값) | 카디널리티 5만짜리 GROUP BY 해시 집계가 이 크기에 걸릴 듯 말 듯함 — `SET work_mem='64MB'`로 재테스트 권장 (아직 안 해봄) |
| `max_parallel_workers_per_gather` | 2 (기본값) | CPU limit이 1이라 병렬 워커 띄울 여유가 사실상 없음 — 리소스 limit과 같이 가야 의미 있음 |
| 인덱스 | 없음 | Ignite와 마찬가지로 아직 안 걸어봄 |

### Trino

| 항목 | 현재 상태 | 개선 방향 |
|---|---|---|
| Worker | 0대 (coordinator 단독) | 오늘 측정한 쿼리는 전부 소스 엔진에 pushdown돼서 worker 유무가 무관했음 — worker 증설은 여러 소스 JOIN이나 pushdown 안 되는 연산에서나 효과. 지금 결과만으로 "worker부터 늘리자"고 판단하면 안 됨 |
| 측정 방식의 고정 오버헤드 | 매 쿼리 1.3~2초 (`kubectl exec` + CLI 새 JVM 기동) | 실제 서비스는 상시 연결 클라이언트를 쓰므로 이 비용은 대부분 사라짐 — 다음 벤치마크는 상시 연결(JDBC 커넥션 재사용) 기반으로 재는 게 더 정확 |

### 다음 세션 후보 (아직 검증 안 된 것)

- PostgreSQL `work_mem` 상향 후 GROUP BY 재측정
- PostgreSQL/Ignite 리소스 limit을 데이터 크기에 맞게 올린 뒤 전체 쿼리셋 재측정
- Ignite 멀티 노드(2~3 replica)로 늘려서 노드 간 파티션 분산 효과 실측
- 비-PK 필터 컬럼에 인덱스 걸고 필터 쿼리 재측정
- 상시 연결 클라이언트로 고정 오버헤드 없이 재측정
