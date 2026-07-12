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
   PostgreSQL 쪽도 리소스 limit이 테이블 크기(1.1GB)보다 작다는 별개의 병목이 있어서로 보임.

**교훈**: "왜 느린지" 판단할 때 (1) Trino pushdown 여부를 `EXPLAIN`으로 먼저 확인하고,
(2) 의심 가는 엔진에 직접 붙어서 같은 쿼리를 재보고, (3) 그 엔진의 실제 설정(카탈로그/캐시
메타데이터)을 확인하는 순서로 좁혀나가는 게 효과적이었다. 추측만으로 결론 내리지 않고
매 단계 실측으로 확인.

### 2-5. 리소스를 맞추고 PostgreSQL을 튜닝하니 판도가 뒤집혔다

2-4의 결론(parallelism 튜닝 후에도 Ignite가 COUNT(*)/PK조회는 우세)은 사실 **두 파드의 리소스가
불공정하게 배분된 상태**(Ignite: cpu limit 4/memory 30Gi, PostgreSQL: cpu limit 1/memory 1Gi)
에서 나온 결과였다. 두 파드를 동일 스펙(cpu limit 4/memory 16Gi)으로 맞추고, PostgreSQL의
`shared_buffers`(128MB→4GB)/`work_mem`(4MB→256MB)/병렬 워커 설정도 그 메모리를 실제로 쓰도록
같이 올린 뒤 재측정하니:

- PostgreSQL 직접 질의가 튜닝 전 대비 전 쿼리에서 약 4배씩 빨라짐(GROUP BY 4.32s→1.07s 등)
- **이제 거의 모든 쿼리에서 PostgreSQL이 Ignite를 앞선다** — 특히 JOIN은 12배(17.27s vs 1.46s)
- 반대로 Ignite는 메모리 limit을 30Gi→16Gi로 줄인 영향(힙 6g→4g, off-heap 23GB→10GB)으로
  일부 쿼리(단순 필터 등)가 오히려 느려짐

자세한 수치는 `docs/test-results-summary.md` 5장. **교훈**: 엔진 간 성능 비교는 반드시 동일한
리소스 조건에서 해야 하며, 그렇지 않으면 "어느 엔진이 빠르다"는 결론이 실은 "어느 쪽에 리소스를
더 줬는지"를 측정한 것에 불과할 수 있다.

### 2-6. Trino는 JOIN을 커넥터로 내려보내지 않는다

COUNT(*)/GROUP BY는 `EXPLAIN`으로 보면 소스 엔진 쿼리 문자열에 통째로 pushdown되지만, **JOIN은
다르다** — Trino 자신의 분산 조인 엔진(`InnerJoin`, `PARTITIONED` distribution)이 처리하고, 각
테이블은 단순 스캔만 커넥터로 내려간다. 그래서 JOIN에서는 "Trino 경유"와 "엔진 직접 질의"의
차이가 다른 쿼리보다 훨씬 크게 벌어진다 (PostgreSQL 기준 11.29s→1.46s, 거의 8배) — 이건 평소의
Trino/JDBC 왕복 고정비용이 아니라 **Trino 자체의 조인 실행 비용**이다. 여러 테이블을 자주
JOIN해서 쓸 계획이면, Trino의 조인 성능이 병목이 될 수 있다는 걸 감안해야 한다.

### 2-7. Ignite는 `query_parallelism`이 다른 테이블끼리 네이티브 JOIN이 안 된다

`query_parallelism=1`(기본값)로 만든 테이블과 `query_parallelism=4`로 만든 테이블을 직접 JOIN하면
`Using indexes with different parallelism levels in same query is forbidden` 에러가 난다.
**앞으로 서로 JOIN할 가능성이 있는 테이블들은 반드시 같은 parallelism으로 통일해서 만들어야
한다** — 튜닝한답시고 테이블마다 다른 값을 주면 나중에 JOIN이 아예 안 되는 걸 뒤늦게 발견하게 됨.

### 2-8. 인덱스가 있다고 옵티마이저가 항상 잘 쓰는 건 아니다

`iot_events.device_id`에 인덱스를 추가하고 재측정하니, 단순 필터와 JOIN은 크게 개선됐지만
**GROUP BY는 오히려 2배 느려졌다**(5.91s→12.05s, 직접 질의 기준). `EXPLAIN`으로 확인해보니
Ignite 옵티마이저가 새 인덱스를 이용한 "group sorted"(인덱스를 정렬 순서대로 훑으며 그룹핑)
전략을 선택했는데, 이게 기존의 "풀스캔 + 인메모리 해시 집계"보다 느렸다 — 900만 행 전체를
다뤄야 하는 쿼리에 인덱스 순회가 오히려 손해였던 것.

같은 인덱스, 같은 상황에서 PostgreSQL은 "Parallel Index Only Scan"으로 인덱스를 활용해 GROUP BY도
**개선**(1.07s→0.52s)시켰다. 즉 **인덱스를 걸 때 "이 컬럼에 인덱스가 있으면 무조건 좋다"가
아니라, 그 인덱스를 실제로 쓸 쿼리들이 어떤 성격(point lookup vs 전체 스캔 집계)인지, 그리고
그 엔진의 옵티마이저가 그 상황에서 올바른 선택을 하는지까지 확인해야 한다** — 옵티마이저의
성숙도 차이가 여기서도 드러났다.

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
| ★ `query_parallelism` | 4로 상향, 2.1배 개선 확인 | CPU limit을 늘리면 그만큼 더 올릴 여지 있음 — 반드시 cgroup 기준 실제 할당량으로 맞출 것(`nproc`는 host 값이라 오해 소지). JOIN할 테이블들은 반드시 같은 값으로 통일할 것(2-7 참고) |
| ★ 메모리 축소 영향 확인 | limit 30Gi→16Gi(힙 6g→4g, off-heap 23GB→10GB)로 줄이니 단순 필터 등 일부 쿼리가 오히려 느려짐 | 16Gi가 이 데이터량(9M행)엔 빠듯한 것으로 보임 — off-heap을 다시 늘리거나(가능하면), 데이터량 대비 적정선을 다시 찾아볼 것 |
| 노드 수 | 1개 (single replica) | 여러 노드로 늘리면 파티션이 노드 간에도 분산돼 `query_parallelism`과 별개로 추가 병렬화 가능 — 아직 안 써본 레버 |
| WAL 모드 | `LOG_ONLY` | `FSYNC`(더 안전, 더 느림)와의 트레이드오프 재검토, 체크포인트 주기(`checkpointFreq`, 현재 180000ms)도 튜닝 대상 |
| ★ 보조 인덱스 (`device_id`) | 추가함, 단순 필터 5배·JOIN 6배 개선(직접 질의 기준) | 반대로 GROUP BY는 2배 악화(5.91s→12.05s) — 옵티마이저가 인덱스를 쓰는 "group sorted" 전략을 골랐는데 이게 더 느렸음(2-8 참고). 워크로드가 집계 위주면 인덱스를 안 걸거나, 힌트로 강제 풀스캔을 검토할 것 |
| JOIN 성능 | 인덱스 추가로 17.27s→2.93s로 대폭 개선 | 여전히 PostgreSQL(1.46s)보단 느림 — 조인 키를 affinity key로 맞춘 collocated join까지 적용하면 추가 개선 여지 있음(2-6, 2-7 참고) |
| 인덱스 생성 자체 속도 | 900만 행 기준 60.6초 (PostgreSQL은 4.1초) | 온라인으로 인덱스를 거는 운영 시나리오라면 이 소요 시간도 고려 대상 |

### PostgreSQL

| 항목 | 현재 상태 | 개선 방향 |
|---|---|---|
| ★ Pod 리소스 limit | cpu 1→4, memory 1Gi→16Gi로 상향, Ignite와 동일 스펙 | 직접 질의 기준 전 쿼리 약 4배 개선 확인 |
| ★ `shared_buffers` | 128MB→4GB | 1.1GB 테이블이 이제 캐시에 다 올라감 — 데이터가 더 커지면 이 비율(약 25%) 유지하며 같이 올릴 것 |
| ★ `work_mem` | 4MB→256MB | GROUP BY 해시 집계 스필 해소로 추정, 큰 개선 확인 |
| ★ `max_parallel_workers_per_gather` | 2→4 | CPU limit 상향과 같이 적용, 개선에 기여 |
| ★ 보조 인덱스 (`device_id`) | 추가함, 단순 필터 2배(0.50s→0.23s)·GROUP BY 2배(1.07s→0.52s) 개선 | 옵티마이저가 "Parallel Index Only Scan"으로 똑똑하게 활용 — Ignite와 달리 인덱스 추가로 손해 보는 쿼리가 하나도 없었음 |
| JOIN 성능 | 인덱스 추가해도 1.46s로 변화 없음 | 이미 충분히 빨라서(원래도 Ignite 대비 12배) 인덱스 유무가 체감되지 않는 수준 |

### Trino

| 항목 | 현재 상태 | 개선 방향 |
|---|---|---|
| Worker | 0대 (coordinator 단독) | COUNT(*)/GROUP BY는 소스 엔진에 pushdown돼서 worker 유무가 무관했지만, **JOIN은 Trino 자신의 엔진이 처리**하는 걸 확인함(2-6) — JOIN이 잦은 워크로드라면 worker 증설이 실제로 효과 있을 가능성이 높음. 이전엔 "worker부터 늘리지 말자"고 했는데, JOIN 결과를 보면 재검토할 만함 |
| 측정 방식의 고정 오버헤드 | 매 쿼리 1.3~2초 (`kubectl exec` + CLI 새 JVM 기동) | 실제 서비스는 상시 연결 클라이언트를 쓰므로 이 비용은 대부분 사라짐 — 다음 벤치마크는 상시 연결(JDBC 커넥션 재사용) 기반으로 재는 게 더 정확 |

### 다음 세션 후보 (아직 검증 안 된 것)

- Ignite off-heap을 16Gi 한도 내에서 다시 조정(예: heap 3g/off-heap 11GB)해서 단순 필터 성능 회복되는지 확인
- Trino worker를 실제로 늘려서 JOIN 쿼리가 얼마나 개선되는지 실측 (지금까지 worker 0대로만 테스트함)
- Ignite GROUP BY가 인덱스 때문에 느려진 문제 — 힌트로 풀스캔을 강제했을 때 원래 속도(5.91s)로
  돌아오는지 확인, 혹은 조인 키를 affinity key로 맞춘 collocated join 적용
- Ignite 멀티 노드(2~3 replica)로 늘려서 노드 간 파티션 분산 효과 실측 (JOIN 성능 포함)
- 상시 연결 클라이언트로 고정 오버헤드 없이 재측정
