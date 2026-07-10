# 대용량(900만 건) 합성 데이터 테스트 — Ignite vs PostgreSQL

> 배경: 실 서비스 예상 물량(하루 90만 건)의 10배인 900만 건을 가정하고, 실제로 그 규모의
> 데이터를 만들어서 Ignite/PostgreSQL 두 엔진에 넣고 측정했다. Redis는 제외했다
> (`docs/redis-exclusion-rationale.md` 참고).

## 1. 데이터 생성 방식

`sample/`의 OMOP CSV는 이 테스트 목적(임의 컬럼 구성으로 대량 생성)에 맞지 않아서, 컬럼/타입을
직접 정의하면 그에 맞는 무작위 값을 생성해주는 스크립트(`scripts/generate-synthetic-data.py`)를
새로 만들었다. 외부 패키지 없이 표준 라이브러리(`random`, `csv`, `datetime`)만 써서 airgap에서도
그대로 동작한다.

이번 테스트에 쓴 스키마(`scripts/schema-example.json`) — IoT/이벤트성 데이터를 가정:

```json
{
  "table": "iot_events",
  "primary_key": "event_id",
  "columns": [
    { "name": "event_id", "type": "bigint", "gen": "sequence" },
    { "name": "device_id", "type": "bigint", "gen": "random_int", "min": 1, "max": 50000 },
    { "name": "event_type", "type": "varchar", "gen": "choice", "values": ["TEMP","HUMIDITY","PRESSURE","VIBRATION","BATTERY"] },
    { "name": "value", "type": "double", "gen": "random_float", "min": 0, "max": 1000 },
    ...
  ]
}
```

10개 컬럼(bigint 4개, double 1개, varchar 5개), 일부 컬럼엔 `null_rate`로 결측치도 섞음
(실제 샘플 데이터가 컬럼 상당수가 비어있던 것과 비슷하게).

```bash
python3 scripts/generate-synthetic-data.py \
  --schema scripts/schema-example.json --rows 9000000 --out /tmp/synthetic-9m.csv
```

9,000,000행 생성에 **2분 54초**, 결과 CSV 파일 크기 **703MB** (행당 평균 78바이트, raw CSV 기준).

## 2. 적재 방식 — Trino가 아니라 네이티브 COPY

처음엔 기존 방식(Trino `INSERT` 배치)을 쓰려 했지만, 이 규모에서는 부적합하다고 판단했다:
- Trino 커넥터는 `COPY` 프로토콜을 지원하지 않는다 — 대량 삽입은 결국 수만 개의 `INSERT`문을
  반복 실행하는 것뿐인데, 이전 테스트(46K행)에서 이미 이 방식으로 coordinator가 OOM난 적이 있다.
- 그래서 **적재는 각 엔진의 네이티브 벌크로드 기능으로 우회**하고, Trino는 이후 조회에만 쓰기로 함.
  - PostgreSQL: `psql \copy` (`scripts/bulk-load-postgresql.sh`)
  - Ignite: SQL `COPY FROM ... INTO ... FORMAT CSV` (Ignite에 내장된 `sqlline.sh`로 실행,
    `scripts/bulk-load-ignite.sh`)
- 테이블 자체는 그대로 Trino `CREATE TABLE`로 만들어서, 두 방식이 같은 물리 테이블을 보게 함.

### 실측 적재 시간 (900만 행)

| 엔진 | 적재 방식 | 소요 시간 | 처리량 |
|---|---|---|---|
| PostgreSQL | `psql \copy` | 약 30초 (COPY 자체) | ~300,000행/초 |
| Ignite | SQL `COPY` (sqlline) | 106.6초 | ~84,000행/초 |

둘 다 하루 900만 건(평균 초당 104건)이라는 목표치에 비하면 압도적으로 여유롭다. 즉 **쓰기
처리량은 두 엔진 다 문제가 안 된다** — 이건 지난 대화에서의 예상과 일치한다.

## 3. 스토리지 — 지난 예상과 실측 비교

지난 대화에서 "Ignite는 지금(112K행, 테이블 10개 × 파티션 1024개) 수치를 그대로 곱하면 안 되고,
테이블 하나에 900만 행이 몰리면 파티션당 행 수가 늘어서 오히려 바이트/행이 줄어들 것"이라고
예상했었다. 실측 결과:

| 엔진 | 900만 행 실제 크기 | 바이트/행 |
|---|---|---|
| PostgreSQL | 1,119 MB | ~130 B |
| Ignite (데이터 페이지만, WAL 제외) | 약 2.0GB (전체 2.7GB 중 기존 OMOP 테이블분 0.7GB 제외) | ~222 B |

예상이 맞았다 — 이전 112K행 테스트에서 관측된 6.4KB/행(파티션 구조 오버헤드가 실데이터를 압도)과
달리, 단일 테이블에 900만 행이 들어가니 파티션당 행 수(1024개 기준 파티션당 ~8,800행)가 충분해져서
바이트/행이 오히려 PostgreSQL과 비슷한 수준(220B대)으로 떨어졌다. **테이블 개수 대비 파티션 수가
아니라, "파티션 하나가 얼마나 많은 행을 담당하는가"가 진짜 변수였다**는 게 확인된 셈.

Ignite WAL은 833MB → 1.2GB로 늘었지만 이건 `walSegments`/`maxWalArchiveSize` 설정으로 정해진
상한 근처라 데이터량에 비례해서 계속 느는 값은 아니다.

## 4. 성능 테스트 결과 — 예상과 다르게 나온 부분이 있다

`scripts/perf-test.sh iot_events event_id device_id`로 측정:

| 쿼리 | ignite | postgresql |
|---|---|---|
| `COUNT(*)` 전체 스캔 | **1.61s** | 6.36s |
| `WHERE event_id = ?` (PK 조회) | **1.41s** | 3.41s |
| `GROUP BY device_id` (카디널리티 50,000) | 12.62s | **4.81s** |
| `COUNT(*)` 재실행(warm) | **1.56s** | 3.12s |

**COUNT(*)와 PK 조회는 예상대로 Ignite가 확실히 빠르다** (인메모리 + 파티션 라우팅의 이점).

**하지만 GROUP BY는 반대로 PostgreSQL이 2.6배 빠르게 나왔다.** 이건 지난 예측("Ignite가 분산
SQL이라 유리할 것")과 어긋나는 실측 결과라 그대로 기록해둔다. 짐작 가는 원인은 카디널리티가 높은
(디바이스 5만 종) GROUP BY를 단일 노드에서 처리할 때, PostgreSQL의 해시 집계 최적화가
Ignite(H2 기반 SQL 엔진)의 처리 방식보다 이 케이스에 한해 더 효율적이었을 가능성 — 다만 이건
가설이고, 여러 노드로 Ignite를 늘렸을 때(파티션별 부분 집계 병렬화) 결과가 달라질 여지는 있다.
**"Ignite가 항상 이긴다"는 가정은 위험하다는 걸 보여주는 실측 사례**로 남겨둔다.

## 5. 재현 방법

```bash
python3 scripts/generate-synthetic-data.py \
  --schema scripts/schema-example.json --rows 9000000 --out /tmp/synthetic-9m.csv --seed 42

./scripts/bulk-load-postgresql.sh /tmp/synthetic-9m.csv
./scripts/bulk-load-ignite.sh /tmp/synthetic-9m.csv

./scripts/perf-test.sh iot_events event_id device_id
```

컬럼/타입을 바꾸고 싶으면 `scripts/schema-example.json`을 복사해서 원하는 컬럼 구성으로
고치면 된다 (지원하는 `gen` 전략은 스크립트 상단 docstring 참고).
