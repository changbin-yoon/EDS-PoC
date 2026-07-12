# Airflow 메타정보 파이프라인 — DB 선택과 근거

> 작성일: 2026-07-13
> 배경: 수천 개의 Airflow DAG가 데이터 마이그레이션 후 메타정보를 중간 DB에 INSERT하고,
> 1일 지난 데이터는 Iceberg+S3로 이관하며, Trino에 여러 카탈로그를 붙여 데이터메시 형태로
> 뷰를 제공하는 구조를 검토해달라는 요청에 대한 답. 지금까지 이 저장소에서 실제로 테스트한
> Ignite/PostgreSQL/Redis 결과를 근거로 삼았다 — 새로 테스트한 건 없고, 기존 실측치를
> 이 시나리오에 대입해서 판단한 것이다.

---

## 1. 결론부터

**중간 메타정보 저장소는 PostgreSQL, 앞단에 PgBouncer는 필수, Redis와 Ignite는 이 경로에서
뺀다.** 아키텍처는 이렇게 된다.

```
[Airflow DAG 수천 개]
      │ (짧은 커넥션, INSERT)
      ▼
[PgBouncer (Pooler, transaction mode)]   ← 연결 폭주 흡수, 선택이 아니라 필수
      ▼
[PostgreSQL (CNPG, primary + replica)]   ← 메타정보 hot store (최근 1일)
      │  - dag_id / 실행일자 / 대상테이블 / 상태 컬럼에 인덱스
      │
      │ (매일 배치 DAG, 1일 지난 행)
      ▼
[Iceberg on S3/MinIO]                    ← cold store (1일 이상)
      │  - Postgres에서 벌크 export는 Spark나 COPY 기반으로 (Trino INSERT로 하지 말 것)
      │  - export 성공 후 Postgres에서 해당 행 DELETE (hot store를 계속 작게 유지)
      ▼
[Trino 데이터메시]
      catalog: postgresql(hot) + iceberg(cold, 같은 스토리지)
      → CREATE VIEW metadata AS
          SELECT * FROM postgresql.public.metadata
          UNION ALL
          SELECT * FROM iceberg.default.metadata_archive;
      → 소비자는 신선도 상관없이 이 뷰 하나만 조회
```

아래는 왜 PostgreSQL을 골랐는지, 그리고 Redis·Ignite를 왜 뺐는지를 실측 근거와 함께 정리한 것.

---

## 2. 왜 PostgreSQL인가

**"수천 개 DAG가 삽입한다"는 조건 자체가, 이미 우리가 직접 겪은 시나리오다.**
Airflow task는 보통 짧게 연결해서 INSERT 하나 하고 끊는 패턴이다. 이건 PgBouncer 검증 때
100 동시접속으로 재현했던 상황과 사실상 같다 — 직결은 `max_connections` 슬롯이 바닥나서
`FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute`로
일부 접속이 아예 실패했고, PgBouncer(Pooler, transaction 모드)는 `default_pool_size`로 실제
백엔드 연결을 눌러놔서 같은 부하를 에러 없이 처리했다(`docs/test-results-summary.md` 9-3d).
수천 개 DAG면 이 위험이 이론이 아니라 실제로 터질 상황이다 — 그래서 PgBouncer는 옵션이 아니라
전제조건으로 잡았다.

**"메타정보 조회"는 전형적으로 SELECT + WHERE + JOIN 워크로드다.** DAG ID로 찾고, 실행일자로
찾고, 상태값으로 걸러내고, 다른 메타 테이블과 조인하는 패턴 — 이건 예전에 "파일 경로 조회"
유스케이스를 검토할 때 이미 정리했던 것과 같은 성격의 워크로드다(`docs/db-engine-evaluation-report.md`
6-5). 그리고 이 워크로드에서 인덱스를 건 PostgreSQL이 지금까지 가장 확실하게 이겼다 — 900만
행 규모에서 단순 필터 0.23초, JOIN 1.46초, 인덱스를 추가해서 손해를 본 쿼리가 단 하나도 없었다.

**1일 지난 데이터를 지워서 hot 테이블을 계속 작게 유지한다는 것도 중요하다.** 테이블이 작을수록
인덱스도 작고, `shared_buffers`에 통째로 올라가고, 오늘 확인한 튜닝 효과(GROUP BY 4배 개선 등)가
계속 유지된다. 안 지우고 쌓이게 두면 결국 900만 행 테스트에서 겪었던 문제(리소스가 데이터량을
못 따라가는 상황)가 그대로 재현된다.

---

## 3. Redis가 안 맞는 이유

**1) 이 파이프라인의 조회 패턴 자체가 Redis의 구조적 한계와 정면충돌한다.**
"메타정보 조회"는 실제로는 "이 DAG가 언제 실패했는지", "이 테이블을 다룬 마이그레이션 중 특정
기간 것", "상태값이 FAILED인 것만" 같은 조건 검색이 대부분일 것이다. Trino의 Redis 커넥터는
서버사이드 필터링이 아예 없어서(`docs/lessons-learned.md` 2-1), `WHERE` 조건이 뭐든 테이블에
속한 키를 전부 SCAN + HGETALL로 끌어온 다음 Trino가 걸러낸다. 실측으로도 PK 조회(가장 유리해야
할 케이스)조차 2.98초로 Ignite(1.45초)·PostgreSQL(1.51초)보다 느렸다 — 조건 검색이면 격차는
더 벌어진다.

**2) "1일 지난 데이터를 Iceberg로 이관"하는 아카이빙 스텝 자체를 못 만든다.**
이 작업은 본질적으로 `created_at < now() - 1day`라는 범위 조건 조회 → 벌크 export → 삭제다.
Redis는 이런 범위 조건을 걸 인덱스 개념이 없어서 "1일 지난 것 찾기"조차 전체 스캔해야 한다.
데이터가 쌓일수록(수천 DAG × 매일 실행) 이 스캔 비용도 계속 늘어나는데, 정작 이걸 매일
반복해야 하는 배치 작업이라 부담이 누적된다.

**3) Trino로는 애초에 쓰기가 안 된다.**
DAG가 메타정보를 넣으려면 Trino/JDBC 경로가 아니라 `redis-cli`나 별도 클라이언트로 직접
넣어야 한다(이번 세션 내내 그렇게 했다). "DAG마다 중간 DB로 INSERT"라는 요구사항과 맞추려면
파이프라인에 완전히 다른 쓰기 경로를 하나 더 만들어야 하고, 트랜잭션/스키마 강제도 없어서
메타정보 정합성 관리가 애플리케이션 책임으로 넘어간다.

**남는 자리**: "DAG ID를 이미 알고 있고 최신 상태만 초고속으로 조회하고 싶다" 같은 좁은 캐시
용도는 여전히 유효하다 — 다만 그건 Trino 데이터메시 뷰에 넣을 게 아니라, 애플리케이션이
직접 붙는 보조 캐시로 완전히 분리해야 한다.

---

## 4. Ignite가 안 맞는 이유

**1) 이 워크로드는 Ignite가 강점을 보이는 영역이 아니다.**
Ignite가 실제로 이기는 지점은 "노드를 늘렸을 때의 분산 집계/스트림 흡수"였는데(3노드+affinity
key로 GROUP BY 5.91초→2.58초), 그마저도 단순 필터·JOIN에서는 인덱스든 3노드든 PostgreSQL을
끝내 못 따라잡았다(JOIN: Ignite 최선의 결과가 2.93~3.57초인데 PostgreSQL은 1.46초). "메타정보를
조건 검색/조인"하는 이 파이프라인은 정확히 PostgreSQL이 이기는 워크로드 모양이다.

**2) 원래 설계 의도와 다른 용도로 억지로 쓰는 셈이다.**
`ignite-config.xml` 주석에 있듯 이 배포의 Ignite는 "Kafka에서 초당 수만 건 들어오는 스트림을
잠깐 담아두는 hot buffer"용으로 설계됐다. 지금 얘기하는 건 "Airflow DAG가 끝나고 나서 결과
몇 줄을 INSERT"하는, 빈도도 훨씬 낮고 성격도 다른 트랜잭션 쓰기다. 애초에 이 유스케이스를
겨냥한 설계가 아니다.

**3) 이번 세션에서 겪은 운영 리스크가 전부 "많은 테이블·많은 쿼리 패턴"을 다뤄야 하는
시스템에서 특히 부담된다.**
- 인덱스 하나 걸었더니 GROUP BY가 2배 느려졌다(옵티마이저가 잘못된 실행계획을 선택). 메타정보
  테이블은 DAG ID로도 찾고, 날짜로도 찾고, 상태로도 찾을 텐데, Ignite에서 다양한 컬럼에
  인덱스를 걸 때마다 다른 쿼리가 망가지지 않는지 매번 검증해야 한다. PostgreSQL은 이런
  부작용이 한 번도 없었다.
- `query_parallelism`이 다른 테이블끼리는 네이티브 JOIN 자체가 안 된다. 메타정보 테이블이
  여러 개고 서로 조인해야 한다면, 테이블을 만들 때마다 parallelism을 통일해야 한다는 제약이
  계속 따라다닌다.
- StatefulSet/baseline 수동 관리, discovery 설정, `tryStop` 버그 등 — 이번에 실제로 여러 번
  장애를 만들었던 지점들이다. 수천 개 DAG가 의존하는 시스템에 이런 운영 부담을 얹는 건
  리스크 대비 이득이 없다.

**4) 디스크 비용도 안 맞는다.**
같은 데이터량 기준 Ignite가 PostgreSQL보다 5.8배(복제 비용을 빼도 2.9배) 더 쓴다. 메타정보는
"1일만 hot에 두고 나머진 Iceberg로 이관"하는 구조라 hot 저장소 자체는 작게 유지되긴 하지만,
그래도 같은 양을 담는 데 굳이 더 비싼 엔진을 쓸 이유가 없다.

**5) "수천 DAG의 동시 쓰기 폭주"에 대한 검증된 안전장치가 없다.**
PostgreSQL은 PgBouncer로 "100 동시접속에서도 안 죽는다"는 걸 오늘 직접 확인했다. Ignite는
이런 연결 폭주 상황에서의 동작을 이번 세션에서 한 번도 테스트하지 않았다 — 검증 안 된 채로
핵심 경로에 쓰는 건 위험하다.

**남는 자리**: 나중에 실제로 DAG 쓰기량이 PostgreSQL+PgBouncer 용량을 넘어서서 수평 쓰기
확장이 꼭 필요해지면, 그때 오늘 정리해둔 교훈들(affinity key 설계, parallelism 통일, 인덱스
부작용 검증)을 바로 적용해볼 여지는 있다 — 다만 지금 요구사항만 놓고 보면 그 정도 규모라는
근거가 아직 없다.

---

## 5. 솔직히 검증 안 된 부분

- **Iceberg/Trino iceberg 카탈로그 자체는 이번 세션에서 한 번도 실측하지 않았다** (Ignite/
  PostgreSQL/Redis/Kafka만 테스트했다). 위 아키텍처의 hot/cold 이관 부분은 일반적인 베스트
  프랙티스에 근거한 설계지, 우리가 직접 잰 숫자는 아니다.
- "수천 개 DAG"가 실제로 초당/분당 몇 건의 INSERT를 만드는지에 따라 PgBouncer
  `default_pool_size`나 Postgres 인스턴스 스펙을 다시 맞춰야 할 수 있다.
- 매일 도는 아카이빙 배치(1일 지난 행 export + delete)의 실제 성능/락 영향은 아직 안 재봤다.

이 세 가지는 다음에 실제로 검증해볼 후보로 남겨둔다.

---

## 6. 참고

- `docs/lessons-learned.md` 2-1(Redis 제외 근거), 2-6(Trino가 JOIN을 pushdown 안 함),
  2-8(Ignite 인덱스 부작용), 2-9(PgBouncer 검증)
- `docs/test-results-summary.md` 1장(112K행 3엔진 비교), 6·8장(인덱스/3노드 결과),
  9장(PgBouncer 동시성 검증)
- `docs/db-engine-evaluation-report.md` 6-5(실시간 파일 조회 유스케이스 — 이번과 같은 성격의
  워크로드 논의)
