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

## 5. 재현 방법

전체 재현 절차는 `docs/airgap-full-test-runbook.md` 참고.
