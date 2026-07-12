# 테스트 결과 종합 (현재까지)

> `dev-cluster`에서 Ignite / PostgreSQL / (초기엔 Redis 포함) 세 엔진을 Trino로 묶어서 실제로
> 테스트한 결과를 전부 모은 문서. 절차(어떻게 재현하는지)는 `docs/airgap-full-test-runbook.md`,
> 버그·아키텍처 관련 통찰은 `docs/lessons-learned.md`를 보고, 여기서는 **숫자와 결론만** 다룬다.

---

## 1. OMOP 샘플 10개 테이블 적재 (112,184행, 3-엔진)

`sample/` CSV 10개(death 포함)를 Ignite/PostgreSQL/Redis 세 곳에 동일 스키마로 적재.

| 테이블 | 행 수 | ignite | postgresql | redis |
|---|---|---|---|---|
| death | 26 | 26 | 26 | 26 |
| care_site | 1,000 | 1,000 | 1,000 | 1,000 |
| person | 1,000 | 1,000 | 1,000 | 1,000 |
| observation_period | 1,000 | 1,000 | 1,000 | 1,000 |
| condition_occurrence | 2,909 | 2,909 | 2,909 | 2,909 |
| condition_era | 4,725 | 4,725 | 4,725 | 4,725 |
| visit_occurrence | 6,336 | 6,336 | 6,336 | 6,336 |
| payer_plan_period | 9,140 | 9,140 | 9,140 | 9,140 |
| observation | 39,832 | 39,832 | 39,832 | 39,832 |
| measurement | 46,216 | 46,216 | 46,216 | 46,216 |
| **합계** | **112,184** | 일치 | 일치 | 일치 |

**112K행 규모 성능 비교** (Trino CLI 경유, `kubectl exec` 왕복 포함, `measurement` 테이블 기준):

| 쿼리 | ignite | postgresql | redis |
|---|---|---|---|
| `COUNT(*)` 전체 스캔 | 1.50s | 1.43s | 2.27s |
| `WHERE person_id = ?` (비인덱스 필터) | 1.64s | 1.60s | 2.38s |
| `WHERE measurement_id = ?` (PK 조회) | 1.45s | 1.51s | 2.98s |
| `GROUP BY` 집계 | 1.72s | 1.48s | 2.68s |
| `measurement JOIN person` | 2.15s | 1.52s | 2.58s |
| `COUNT(*)` 재실행(warm) | 1.48s | 1.46s | 2.25s |

**결론**: Redis가 모든 쿼리에서 가장 느림(PK 조회까지) → 이후 대량 테스트에서 제외
(이유는 `docs/lessons-learned.md` 참고). Ignite/PostgreSQL은 이 규모·단일 노드 기준으로는
비슷한 수준.

---

## 2. 재기동 시 데이터 휘발 테스트 (26행, death 테이블)

세 Pod를 강제로 `kubectl delete pod` 해서 데이터가 남는지 확인.

| 카탈로그 | 재기동 전 | 재기동 후 (persistence 끄기 상태) |
|---|---|---|
| `ignite.public.death` | 26행 | **테이블 자체가 사라짐** |
| `postgresql.public.death` | 26행 | 26행 그대로 |
| `redis.default.death` | 26행 | 26행 그대로 |

Ignite persistence를 켠 뒤(`persistenceEnabled=true`, `walMode=LOG_ONLY`) 다시 테스트하니
재기동 후에도 데이터가 남는 것을 확인 (최초 1회만 `control.sh --activate` 수동 필요, 이후 자동).

---

## 3. PostgreSQL 백업 검증

MinIO(재사용) 대상으로 Barman Cloud(in-tree) 백업/WAL 아카이빙 구성 후 실제로 검증:

- `ContinuousArchiving` 상태 `working` 확인
- 온디맨드 `Backup` 리소스 트리거 → `phase: completed`
- MinIO 버킷에 실제로 `data.tar` **약 53MiB**(적재된 112,184행 전체 분량) 확인

---

## 4. 900만 행 합성 데이터 테스트 (Ignite / PostgreSQL만)

`scripts/generate-synthetic-data.py`로 직접 정의한 10컬럼 스키마(`iot_events`)에 대해 900만 행
생성 후, Trino를 우회한 네이티브 벌크로드(`psql \copy`, Ignite `COPY`)로 적재.

### 4-1. 적재 속도

| 엔진 | 소요 시간 | 처리량 |
|---|---|---|
| PostgreSQL (`psql \copy`) | ~30초 | ~300,000행/초 |
| Ignite (SQL `COPY`, sqlline) | 106.6초 | ~84,000행/초 |

하루 900만 건(평균 초당 104건) 목표치 대비 압도적으로 여유 — **쓰기 처리량은 두 엔진 다 문제 없음.**

### 4-2. 스토리지 (900만 행)

| 엔진 | 크기 | 바이트/행 |
|---|---|---|
| PostgreSQL | 1,119 MB | ~130B |
| Ignite (데이터 페이지, WAL 제외) | ~2.0GB | ~222B |

112K행 규모 테스트(테이블 10개, 각각 파티션 1024개)에서 관측된 Ignite 6.4KB/행(파티션 오버헤드가
실데이터를 압도)과 달리, **단일 테이블에 900만 행이 몰리면 파티션당 행 수가 충분해져서
바이트/행이 PostgreSQL과 비슷한 수준(220B대)까지 떨어짐**을 확인.

### 4-3. 성능 — parallelism 튜닝 전/후

최초 측정(Ignite 테이블의 `QUERY_PARALLELISM`이 기본값 1인 상태):

| 쿼리 | ignite | postgresql |
|---|---|---|
| `COUNT(*)` | 1.61s | 6.36s |
| PK 조회 | 1.41s | 3.41s |
| `GROUP BY device_id` (카디널리티 50,000) | **12.62s** | 4.81s |
| `COUNT(*)` 재실행(warm) | 1.56s | 3.12s |

GROUP BY에서 PostgreSQL이 2.6배 빠르게 나온 원인을 규명한 결과(상세 경위는
`docs/lessons-learned.md`), Ignite 테이블의 `QUERY_PARALLELISM`이 1(파드 CPU limit=4인데도)로
생성된 게 원인이었다. `parallelism=4`로 테이블을 재생성하고 재적재 후 재측정:

| GROUP BY (device_id, 카디널리티 50,000) | parallelism=1 | parallelism=4 |
|---|---|---|
| Trino 경유 | 12.62s | **5.89s** |
| 직접(sqlline, Trino 미경유) | 10.88s | **4.84s** |

**약 2.1배 개선.**

### 4-4. 최종 비교표 (parallelism=4, Trino 경유 vs 엔진 직접 질의)

| 쿼리 | ignite (Trino 경유) | ignite (직접) | postgresql (Trino 경유) | postgresql (직접) |
|---|---|---|---|---|
| `COUNT(*)` | 1.46s | **0.97s** | 3.07s | 1.94s |
| PK 조회 | 1.37s | **0.93s** | 3.37s | 2.19s |
| `GROUP BY device_id` | 5.89s | 4.84s | 4.98s | **4.32s** |
| `COUNT(*)` 재실행(warm) | 1.40s | **0.99s** | 3.11s | 2.10s |

**결론**:
- COUNT(*)/PK 조회는 parallelism 설정과 무관하게 Ignite가 꾸준히 우세 (파티션 카운터/키 라우팅 덕).
- parallelism 튜닝 후에도 GROUP BY는 PostgreSQL이 근소하게 여전히 빠름(4.32s vs 4.84s, 직접
  기준) — 남은 격차의 유력한 원인은 PostgreSQL 쪽도 리소스 limit이 데이터 크기(1.1GB)보다
  작다는 것(다음 튜닝 대상, `docs/lessons-learned.md` 4장 참고).
- "직접 질의"가 "Trino 경유"보다 항상 0.4~2.1초 빠름 — 이게 Trino/JDBC 왕복 고정비용이고,
  상시 연결 클라이언트를 쓰는 실제 운영에서는 대부분 사라지는 비용이다.

---

## 5. 리소스 스펙 통일 + PostgreSQL 튜닝 후 재측정

4장까지는 Ignite(cpu limit 4, memory limit 30Gi, JVM heap 6g)와 PostgreSQL(cpu limit 1, memory
limit 1Gi, 기본 설정)의 리소스가 크게 달랐다 — 공정한 비교가 아니었다는 지적에 따라 **두 파드
스펙을 동일하게(cpu limit 4, memory limit 16Gi) 맞추고**, PostgreSQL도 그 메모리를 실제로 쓰도록
튜닝한 뒤 재측정했다.

### 5-1. 적용한 설정

| 항목 | Ignite | PostgreSQL |
|---|---|---|
| CPU request/limit | 1 / 4 | 1 / 4 |
| Memory request/limit | 8Gi / 16Gi | 8Gi / 16Gi |
| 힙/버퍼 | JVM heap 4g, off-heap max 10GB | `shared_buffers=4GB`, `work_mem=256MB`, `effective_cache_size=12GB` |
| 병렬도 | `query_parallelism=4` | `max_parallel_workers_per_gather=4`, `max_parallel_workers=8` |

Ignite는 메모리 limit을 30Gi→16Gi로 **줄였기** 때문에 힙(6g→4g)/off-heap(23GB→10GB)도 같이
축소했다 — 이 자체가 하나의 변수가 된다(아래 결론 참고).

### 5-2. 추가한 쿼리 — 단순 WHERE 필터, JOIN

기존에 못 해봤던 두 가지를 새로 추가했다: 비-PK 컬럼 단순 필터(`device_id = ?`, 결과 196행)와
JOIN(`iot_events`(900만) x `device_dim`(신규 생성, 5만행 차원 테이블) → 지역별 집계).

### 5-3. 결과 — Trino 경유

| 쿼리 | ignite | postgresql |
|---|---|---|
| `COUNT(*)` | 1.72s | 1.85s |
| PK 조회 | 1.51s | 2.01s |
| **단순 필터** (`device_id = ?`, 비-PK) | 8.74s | **1.89s** |
| `GROUP BY device_id` | 6.37s | **3.52s** |
| **JOIN** (`iot_events` x `device_dim`) | 18.75s | **11.29s** |

### 5-4. 결과 — 엔진 직접 질의 (Trino 미경유)

| 쿼리 | ignite | postgresql |
|---|---|---|
| `COUNT(*)` | 0.94s | **0.48s** |
| PK 조회 | 0.87s | **0.53s** |
| **단순 필터** (`device_id = ?`) | 4.58s | **0.50s** |
| `GROUP BY device_id` | 5.91s | **1.07s** |
| **JOIN** | 17.27s | **1.46s** |

### 5-5. 결론 — 판도가 완전히 바뀌었다

**PostgreSQL 튜닝 효과가 압도적이다.** 직접 질의 기준으로 COUNT(*)/PK조회/GROUP BY가 튜닝 전
대비 전부 약 4배씩 빨라졌고(예: GROUP BY 4.32s→1.07s), 이제 **거의 모든 쿼리에서 PostgreSQL이
Ignite를 앞선다** — 특히 JOIN은 17.27s vs 1.46s로 12배, 단순 필터는 4.58s vs 0.50s로 9배 차이가
났다. `shared_buffers`가 128MB→4GB로 늘면서 1.1GB 테이블 전체가 드디어 메모리에 다 올라갔고,
`work_mem` 256MB로 해시 집계 스필이 없어졌고, 병렬 워커도 CPU 4코어를 실제로 쓸 수 있게 된
효과가 그대로 드러난 것으로 보인다.

**반대로 Ignite는 메모리를 줄인 영향(30Gi/6g힙 → 16Gi/4g힙)으로 일부 쿼리가 오히려 느려졌다** —
같은 parallelism=4인데도 단순 필터가 이전엔 테스트 안 했지만 이번엔 4.58s로 꽤 느리게 나왔다.
9백만 행 + 인덱스 구조를 다루기엔 10GB off-heap이 빠듯했을 가능성이 있다.

**새로 발견한 두 가지 구조적 사실:**

1. **Trino는 JOIN을 커넥터로 내려보내지 않는다.** `EXPLAIN`으로 확인해보니 COUNT(*)/GROUP BY와
   달리 JOIN은 Trino 자신의 분산 조인 엔진(`InnerJoin`, `PARTITIONED` distribution)이 처리하고,
   각 테이블은 그냥 단순 스캔만 커넥터로 내려간다. 그래서 JOIN에서 "Trino 경유"와 "직접"의 차이가
   다른 쿼리보다 훨씬 크게 벌어진다(PostgreSQL: 11.29s→1.46s, 거의 8배) — 이 격차는 Trino/JDBC
   왕복 비용이 아니라 **Trino 자체의 조인 실행 비용**이다.
2. **Ignite는 `query_parallelism`이 다른 테이블끼리 네이티브 JOIN이 안 된다.** `device_dim`을
   기본값(parallelism=1)으로 만들고 `iot_events`(parallelism=4)와 직접 JOIN을 시도하니
   `Using indexes with different parallelism levels in same query is forbidden` 에러가 났다.
   `device_dim`도 parallelism=4로 다시 만들고 나서야 됐다 — **앞으로 서로 JOIN할 테이블들은
   parallelism을 반드시 통일해야 한다**는 실무 제약사항.

**교훈**: 이전 장(4장)까지의 "Ignite가 COUNT(*)/PK조회에서 우세하다"는 결론은 **리소스가 불공정하게
배분된 상태에서 나온 결과였다.** 리소스를 맞추고 나니 그 우위 상당수가 사라지거나 역전됐다 —
엔진 비교는 반드시 동일한 리소스 조건에서 해야 한다는 걸 스스로 증명한 셈이다.

---

## 6. 인덱스 적용 후 재측정

5장까지는 두 엔진 다 PK(`event_id`) 외엔 인덱스가 전혀 없는 상태였다. 자주 필터/조인에 쓰는
`device_id` 컬럼에 인덱스를 걸고(`iot_events.device_id`) 5장과 같은 쿼리셋을 다시 측정했다.

### 6-1. 인덱스 생성 자체도 속도 차이가 컸다

900만 행 기준 `CREATE INDEX`:

| 엔진 | 소요 시간 |
|---|---|
| PostgreSQL | 4.1초 |
| Ignite | 60.6초 |

### 6-2. 결과 — Trino 경유

| 쿼리 | ignite (인덱스 전) | ignite (인덱스 후) | postgresql (인덱스 전) | postgresql (인덱스 후) |
|---|---|---|---|---|
| 단순 필터 (`device_id = ?`) | 8.74s | **1.55s** | 1.89s | 1.64s |
| `GROUP BY device_id` | 6.37s | **13.78s** (악화) | 3.52s | **2.22s** |
| JOIN | 18.75s | **24.47s** (악화) | 11.29s | 11.56s |

### 6-3. 결과 — 엔진 직접 질의 (Trino 미경유)

| 쿼리 | ignite (인덱스 전) | ignite (인덱스 후) | postgresql (인덱스 전) | postgresql (인덱스 후) |
|---|---|---|---|---|
| 단순 필터 | 4.58s | **0.90s** | 0.50s | **0.23s** |
| `GROUP BY device_id` | 5.91s | **12.05s** (악화) | 1.07s | **0.52s** |
| JOIN | 17.27s | **2.93s** | 1.46s | 1.46s (변화 없음) |

### 6-4. 해석 — 인덱스가 항상 이득은 아니다

**단순 필터**는 두 엔진 다 개선(Ignite는 5배, PostgreSQL은 2배) — 예상대로다.

**JOIN은 Ignite에서 극적으로 개선됐다** (직접 질의 기준 17.27s→2.93s, 약 6배). 조인 키에
인덱스가 있으니 상대 테이블의 각 행을 찾을 때 풀스캔 대신 인덱스로 바로 찾아간 것으로 보인다.
PostgreSQL은 원래도 빨랐어서(1.46s) 변화가 거의 없었다.

**GROUP BY는 Ignite에서 오히려 2배 나빠졌다.** `EXPLAIN`으로 확인해보니 Ignite 옵티마이저가
새로 생긴 인덱스를 이용한 "group sorted" 집계 전략을 선택했는데, 이게 기존의 풀스캔+해시 집계보다
느렸다. 즉 **인덱스가 있다고 옵티마이저가 항상 더 나은 계획을 고르는 게 아니다** — 이번 케이스는
Ignite의 비용 기반 최적화가 잘못된 선택을 한 사례로 보인다. 반대로 PostgreSQL은 같은 인덱스를
"Parallel Index Only Scan"으로 활용해 오히려 개선(1.07s→0.52s)됐다 — 옵티마이저 성숙도 차이가
드러난 지점이다.

### 6-5. 결론

인덱스 하나로 상황이 또 한 번 바뀌었다 — **JOIN과 단순 필터는 Ignite도 인덱스 덕에 크게
개선되어 PostgreSQL과 격차가 좁혀지거나(단순 필터) 비슷한 수준까지 따라왔지만(JOIN, 직접 질의
기준 2.93s vs 1.46s), GROUP BY는 인덱스가 Ignite에는 오히려 독이 됐다.** 워크로드 성격에 따라
인덱스를 걸지 말지, 혹은 쿼리별로 인덱스 사용을 강제/회피하는 힌트가 필요한지 엔진별로 따로
검토해야 한다는 뜻이다. 6-5장(실시간 파일 조회 유스케이스, `docs/db-engine-evaluation-report.md`
참고)처럼 필터/조인 위주 워크로드라면 이번 인덱스 적용으로 두 엔진 다 실사용 가능한 수준에
도달했다고 볼 수 있다.

---

## 7. 재현 방법

전체 재현 절차는 `docs/airgap-full-test-runbook.md` 참고. 인덱스 생성은:

```sql
-- PostgreSQL (psql 직접 접속)
CREATE INDEX idx_iot_events_device_id ON iot_events (device_id);
ANALYZE iot_events;

-- Ignite (sqlline 직접 접속)
CREATE INDEX idx_iot_events_device_id ON PUBLIC.IOT_EVENTS (device_id);
```

---

## 8. Ignite 3노드 확장 + affinity key(collocated join) 재측정

6장의 인덱스는 필터/JOIN엔 도움이 됐지만 GROUP BY엔 오히려 독이었다. 노드를 늘리고 조인 키를
affinity key로 맞추면(인덱스 없이도) 세 쿼리 유형을 다 개선할 수 있는지 확인했다.

### 8-1. 적용한 변경

- Ignite StatefulSet을 1 → **3 replica**로 확장 (워커 노드 3대에 고르게 분산 배치됨)
- 새로 조인된 노드들을 **baseline에 수동 추가**해야 실제로 파티션이 재분배됨(`control.sh
  --baseline add ... --yes`) — 자동 조정이 기본으로 꺼져 있었음
- `iot_events`를 복합 PK `(event_id, device_id)` + **`AFFINITY_KEY=device_id`**로 재생성 —
  `device_dim`(PK가 이미 `device_id`)과 같은 파티션에 데이터가 모이도록(collocated join) 설계
- 두 테이블 다 `backups=1`로(기존 0에서 상향, HA 확보), `query_parallelism=4` 유지
- **6장의 보조 인덱스는 다시 걸지 않음** — affinity key 자체가 `device_id` 조회를 파티션
  라우팅만으로 처리할 수 있으므로, 인덱스 없이 어디까지 되는지 보려는 의도
- 900만 행 + 5만 행 재적재 (백업 있는 상태라 로드 시간은 115.7초로 이전보다 약간 증가)

### 8-2. 결과 — 직접 질의 (Trino 미경유)

| 쿼리 | 1노드, 인덱스 없음 | 1노드, 인덱스 있음 | **3노드 + affinity, 인덱스 없음** | PostgreSQL (인덱스+튜닝) |
|---|---|---|---|---|
| `COUNT(*)` | 0.94s | (측정 안 함) | 1.01s | 0.48s |
| PK 조회 | 0.87s | (측정 안 함) | 0.92s | 0.53s |
| 단순 필터 (`device_id`) | 4.58s | 0.90s | **0.97s** | 0.23s |
| `GROUP BY device_id` | 5.91s | 12.05s (악화) | **2.58s** (최고 기록) | 0.52s |
| JOIN | 17.27s | 2.93s | **3.57s** | 1.46s |

### 8-3. Trino 경유 결과는 참고용일 뿐이다 — JOIN엔 의미 없음

Trino로 같은 JOIN을 돌리면 23.7초가 나왔는데, 이건 **collocation 효과가 전혀 반영 안 된
수치다.** 5장/6장에서 이미 확인했듯 Trino는 JOIN을 커넥터로 내려보내지 않고 자기 엔진에서
처리하기 때문에, Ignite 쪽 테이블을 아무리 collocate 시켜도 Trino는 그냥 두 테이블을 각각
스캔해서 자기가 조인한다 — **collocated join의 이득은 Trino를 거치는 순간 사라진다.**
이번 3노드 collocation 검증은 그래서 직접 질의로만 의미가 있다.

### 8-4. 결론

- **GROUP BY는 3노드 확장이 지금까지 시도한 방법 중 가장 확실한 개선책이었다** — 인덱스는
  오히려 악화시켰는데(5.91s→12.05s), 노드를 늘리니 5.91s→2.58s로 개선됐다. 파티션별 부분
  집계 후 병합이라는 Ignite 본연의 분산 SQL 방식이 이 케이스에 제대로 작동한 것으로 보인다.
- **단순 필터는 인덱스 없이 affinity key 라우팅만으로 인덱스 있는 1노드 수준(0.97s vs 0.90s)에
  도달했다** — 별도 보조 인덱스 없이도 조회가 빨라진다는 점에서, 조인/필터 컬럼이 명확하면
  처음부터 그 컬럼을 affinity key로 설계하는 게 나중에 인덱스를 추가하는 것보다 깔끔한
  해법일 수 있다.
- **JOIN은 개선됐지만(17.27s→3.57s) 여전히 PostgreSQL(1.46s)에는 못 미쳤다.** 인덱스만 걸었을
  때의 1노드 결과(2.93s)보다도 근소하게 느리다 — collocation과 인덱스를 동시에 적용하면
  더 나아질 가능성이 있고, 다음 시도 후보로 남겨둔다.
- **종합적으로 3노드+affinity key 조합이 지금까지 테스트한 Ignite 설정 중 가장 균형 잡힌
  결과였다** — 인덱스처럼 한 쿼리를 살리고 다른 쿼리를 죽이는 트레이드오프 없이, 세 쿼리
  유형 전부 1노드 대비 개선되거나 최소한 나빠지지 않았다. 다만 **PostgreSQL과의 격차는
  모든 쿼리에서 여전히 남아 있다** — 좁혀지긴 했지만(특히 필터·GROUP BY), 아직 역전은 못 했다.
