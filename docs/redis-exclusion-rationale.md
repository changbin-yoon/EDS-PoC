# Redis를 Trino 성능/적재 테스트에서 제외한 이유

앞으로의 대용량 테스트(`scripts/generate-synthetic-data.py`, `bulk-load-*.sh`, `perf-test.sh`,
`verify-row-counts.sh`)는 **Ignite / PostgreSQL 두 엔진만** 다룬다. Redis는 여전히 클러스터에
떠 있고 카탈로그도 살아있지만(`redis.default.*`), 앞으로의 벤치마크/적재 스크립트 대상에서는
의도적으로 뺐다. 이유는 다음과 같다.

## 1. Trino의 Redis 커넥터는 서버사이드 필터링이 없다

`ignite`/`postgresql` 커넥터는 JDBC 기반이라 `WHERE`, `GROUP BY`, 정렬 일부를 실제 엔진(SQL
옵티마이저)으로 내려보낸다(pushdown). Redis 커넥터는 다르다 — 테이블 하나가 사실 "이 prefix로
시작하는 키들의 집합"일 뿐이라, Trino가 조건절을 받으면 **일단 그 테이블에 해당하는 키를 전부
SCAN하고, 각 키를 HGETALL로 끌어온 다음 Trino 엔진 내부에서 필터링**한다. 즉 Redis 서버 입장에서는
"조건에 안 맞는 데이터"까지 전부 네트워크로 퍼올려서 버리는 구조다.

## 2. 실측 결과 — 모든 쿼리 유형에서 가장 느렸다 (112K행 기준)

| 쿼리 | ignite | postgresql | redis |
|---|---|---|---|
| COUNT(*) 전체 스캔 | 1.50s | 1.43s | 2.27s |
| 비인덱스 필터 | 1.64s | 1.60s | 2.38s |
| **PK 조회** | 1.45s | 1.51s | **2.98s** |
| GROUP BY 집계 | 1.72s | 1.48s | 2.68s |

특히 눈여겨볼 건 PK 조회다. Redis의 존재 이유 자체가 "키로 즉시 찾기(O(1))"인데, Trino를 거치는
순간 그 장점이 사라지고 오히려 가장 느린 결과가 나왔다. Trino가 조건절을 Redis 쪽으로 내려서
"그 키 하나만" 가져오게 하질 못하기 때문이다.

## 3. 데이터가 커질수록 격차가 벌어지는 구조다

풀스캔 비용은 (대략) 키 개수에 비례해서 늘어난다. Ignite/PostgreSQL은 인덱스나 파티셔닝으로
이 비용을 줄일 수 있는 여지가 있지만, Redis 커넥터는 애초에 "인덱스"라는 개념 자체가 없어서
데이터가 늘어나는 만큼 그대로 느려진다. 900만 건 같은 대용량 테스트를 Redis까지 포함해서 돌리면
- (a) 의미 있는 결과가 안 나올 게 거의 확실하고 (이미 46K행에서도 제일 느렸다)
- (b) 전체 키를 다 끌어오는 과정에서 Trino coordinator 메모리 부담만 키운다 (측정에 실질적인
  의미가 없는데 리소스만 쓰는 셈)

## 4. 애초에 쓰기 자체가 Trino 경로가 아니다

지금까지 Redis에 데이터를 넣을 때 전부 Trino가 아니라 `redis-cli`로 직접 HSET했다 — Trino의
Redis 커넥터는 **쓰기를 지원하지 않는다.** 반면 Ignite/PostgreSQL은 Trino `INSERT`(소량)나
네이티브 COPY(대량) 둘 다 가능하다. "Trino로 적재하고 Trino로 조회한다"는 이번 테스트의 기본
전제 자체가 Redis에는 처음부터 안 맞았다.

## 결론 — Redis가 쓸모없다는 뜻은 아니다

Redis 자체는 여전히 빠르다(직접 `redis-cli`/애플리케이션 client로 접근하면). 문제는 **Trino를
통한 SQL 페더레이션**이라는 이번 테스트의 프레임이 Redis의 강점(O(1) key-value 조회)과 정면으로
안 맞는다는 것. 따라서:
- Trino로 여러 소스를 SQL 하나로 federate해서 분석 쿼리를 돌리는 용도 → Ignite/PostgreSQL만 사용
- 애플리케이션이 직접 키로 값을 찾는 캐시 용도 → Redis는 그대로 유지, 다만 Trino 카탈로그로
  노출할 필요는 없음 (오히려 노출하면 위 문제 때문에 혼란만 커짐)
