# Trino 뒷단 3개 엔진(Ignite/PostgreSQL/Redis) 운영 점검

> 작성일: 2026-07-10
> 대상: `dev-cluster` 내 `ignite.public.*`, `postgresql.public.*`, `redis.default.*`
> 데이터: OMOP CDM 샘플 10개 테이블(death 포함, 총 112,187행), 세 엔진 모두 동일 스키마·동일 값으로 적재 완료

이 문서는 세 엔진에 같은 데이터를 실제로 넣어보고, 같은 쿼리를 Trino로 돌려보면서 확인한 내용을
정리한 것이다. 이론적인 스펙 비교가 아니라, 오늘 직접 겪은 문제들(설정 오류, OOM, 키 포맷 버그 등)을
포함해서 "실제로 운영하면 뭐가 다른가"에 초점을 맞췄다.

---

## 1. 적재 결과

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

적재 중에 실제로 두 가지 문제가 있었다.

- **Trino coordinator OOM**: `measurement`(46,216행, 19컬럼)을 500행 단위 INSERT로 넣다가 coordinator가
  `OOMKilled` 됐다. 컨테이너 메모리 limit이 2Gi였는데, 대량 리터럴 INSERT를 연속으로 파싱하면서
  누적된 것으로 보인다. limit을 4Gi로 올리고 배치 크기를 150행으로 줄여서 재적재했다.
- **Redis HSET 인자 깨짐**: `condition_occurrence`의 `condition_status_source_value` 컬럼에
  `"Condition to be diagnosed by procedure"`처럼 공백 포함 값이 있었는데, redis-cli에 그냥 넘기면
  공백 기준으로 토큰이 쪼개져서 HSET 인자 개수가 안 맞아 전체 2,909건이 다 실패했다(0건 적재).
  값에 공백이 있으면 따옴표로 감싸도록 스크립트를 고치고 재적재해서 해결.

두 건 다 "데이터 양이 늘어나면 처음 보는 문제"였다는 점은 기억해둘 만하다. death(26행) 테스트에서는
전혀 드러나지 않았던 문제들이다.

---

## 2. 성능 테스트

`measurement` 테이블(46,216행) 기준으로 Trino CLI를 통해 같은 쿼리를 세 카탈로그에 각각 실행하고
`kubectl exec` 왕복 포함 wall-clock 시간을 쟀다. Trino CLI 자체 기동 오버헤드가 매 쿼리마다
약 1.3~1.5초씩 깔려 있어서 절대값보다는 **엔진 간 상대 차이**로 보는 게 맞다.

| 쿼리 | ignite | postgresql | redis |
|---|---|---|---|
| `COUNT(*)` 전체 스캔 | 1.50s | 1.43s | 2.27s |
| `WHERE person_id = ?` (비인덱스 필터) | 1.64s | 1.60s | 2.38s |
| `WHERE measurement_id = ?` (PK 조회) | 1.45s | 1.51s | 2.98s |
| `GROUP BY` 집계 (concept_id별 count/avg) | 1.72s | 1.48s | 2.68s |
| `measurement JOIN person` | 2.15s | 1.52s | 2.58s |
| `COUNT(*)` 재실행(warm) | 1.48s | 1.46s | 2.25s |

몇 가지 눈에 띄는 점:

- **Redis가 모든 쿼리에서 가장 느리다.** PK 조회(원래 Redis가 제일 잘해야 할 케이스)조차 가장 느렸는데,
  이건 Trino의 Redis 커넥터가 조건절을 Redis 서버 쪽으로 내려보내지 못하고 테이블 전체를 SCAN해서
  하나씩 HGETALL로 끌어온 다음 Trino 엔진 내부에서 필터링하기 때문이다. 즉 Redis 자체는 빠른데,
  **Trino를 통해 SQL로 접근하는 순간 Redis의 장점(O(1) key lookup)이 사라진다.**
- Ignite와 PostgreSQL은 대체로 비슷한 수준이고, JOIN에서는 PostgreSQL이 근소하게 더 빠르다.
  PostgreSQL 옵티마이저가 더 성숙한 반면, Ignite는 파티션 프루닝 등 분산 환경에서 진가를 발휘하는
  기능이 지금처럼 단일 노드·소량 데이터에서는 크게 드러나지 않는다.
- 이 테스트는 전부 단일 Ignite 노드, 단일 Redis 인스턴스, 단일 PostgreSQL 인스턴스 기준이다.
  Ignite와 PostgreSQL 모두 "규모가 커지면(멀티 노드, 대용량) 차이가 더 벌어질 잠재력"이 있는 반면,
  Redis 커넥터의 풀스캔 특성은 데이터가 늘어날수록 더 불리해지는 구조라는 점이 중요하다.

---

## 3. Trino 기준으로 본 세 엔진의 차이

같은 SQL 인터페이스로 붙여놨지만 내부적으로 하는 일은 완전히 다르다.

**PostgreSQL** — Trino의 postgresql 커넥터는 조건절/정렬/집계 일부를 실제 PostgreSQL 쪽으로
푸시다운한다. 진짜 RDBMS라서 옵티마이저, 트랜잭션, 제약조건(FK/UNIQUE 등, 이번 테스트에서는 안 썼지만)이
다 있다. Trino 입장에서는 "가장 예측 가능하게 동작하는" 소스.

**Ignite** — Trino의 ignite 커넥터는 JDBC 기반이고, Ignite 자체가 분산 SQL 엔진이라 파티셔닝
기반의 병렬 처리가 가능하다(지금은 1노드라 의미가 제한적). 클러스터 확장 시(replica 늘리기) 진짜
장점이 나오는 구조이고, 지금처럼 단일 노드에서는 "메모리에 다 올라간 PostgreSQL"과 큰 차이가 없다.
다만 오늘 여러 번 겪었듯 **discovery, 클래스패스 모듈, persistence 설정 등 신경 쓸 파라미터가
셋 중 가장 많다.**

**Redis** — Trino의 redis 커넥터는 사실상 "테이블처럼 보이게 해주는 어댑터"에 가깝다.
서버 사이드 필터링/인덱스가 없고, 테이블 디스크립션(JSON)에 스키마를 미리 선언해둬야 하며,
쓰기는 지원하지 않는다(오늘도 데이터 적재는 Trino가 아니라 `redis-cli`로 직접 했다). SQL로 복잡한
쿼리를 돌리는 용도가 아니라, **키로 즉시 찾아야 하는 단건 조회 캐시**로 쓸 때 의미가 있는 구조.
Trino를 거쳐서 쓰는 순간 이미 Redis의 강점을 포기하는 셈이라, "Trino 연동용 Redis"는 조회 성능보다는
"다른 두 시스템에 없는 실시간 캐시 데이터를 SQL 조인에 잠깐 끼워넣고 싶을 때"용으로 보는 게 맞다.

---

## 4. 관리 측면에서 어디가 괜찮은가

**PostgreSQL (CNPG)**
- CloudNativePG 오퍼레이터가 관리해줘서 세 시스템 중 가장 "K8s스럽게" 운영된다 — Cluster CRD 하나로
  선언적으로 관리되고, 장애 시 오퍼레이터가 자동으로 재기동을 처리해준다(오늘 재기동 테스트에서도
  가장 손이 안 갔다).
- 다만 **지금 이 클러스터엔 백업 설정이 전혀 없다.** `cnpg-cluster.yaml`에 `backup`/Barman 관련
  섹션이 없어서, PVC가 통째로 날아가면 복구 수단이 없다. 이건 프로덕션으로 가기 전에 반드시
  메워야 할 구멍이다.
- WAL 기반이라 크래시에도 커밋된 데이터는 안전하다는 확신을 가장 크게 가질 수 있는 시스템.

**Redis**
- 셋 중 설정이 제일 단순하고 운영 부담이 적다. AOF(`appendonly yes`) + RDB 스냅샷 조합으로
  재기동에도 데이터가 남는다는 걸 이미 확인했다.
- 다만 `maxmemory 512mb` + `allkeys-lru`가 걸려 있어서, **재기동과 무관하게 데이터가 늘어나면
  오래된 키가 조용히 사라질 수 있다.** 지금은 112K건 넣고도 52MB밖에 안 써서 여유가 크지만,
  운영 데이터로 채워질수록 이 한도를 계속 지켜봐야 한다.
- Redis Sentinel/Cluster 같은 HA 구성은 지금 안 되어 있음 — 단일 인스턴스라 그 자체가 SPOF.

**Ignite**
- 셋 중 설정 항목이 가장 많고, 오늘 실제로 제일 많이 삽질한 시스템이다(discovery 클래스 로딩 실패,
  `tryStop` 프로퍼티 버그, persistence 활성화 시 수동 activate 필요 등). 운영 난이도가 명백히 제일 높다.
- 대신 persistence를 제대로 켜두면(오늘 처음 설정을 바로잡음) 재기동에도 데이터가 남고, 분산 SQL +
  인메모리 성능이라는 조합을 노릴 수 있다. 다만 지금 이 배포는 원래 "Kafka hot buffer" 용도로
  설계된 것이라, persistence를 켜서 쓰는 게 원래 아키텍처 의도와는 다르다는 점은 염두에 둬야 한다.
- 단일 replica라서 Ignite의 핵심 장점(파티션 분산, 노드 장애 시 자동 rebalance)은 지금 구조에서는
  사실상 안 쓰고 있는 것과 같다.

---

## 5. 장애 발생 시 복구 절차

### PostgreSQL (CNPG)

1. `kubectl get cluster -n cnpg eds-pg` 로 상태 확인. `Cluster` CR이 있으면 오퍼레이터가 이미
   재기동을 시도 중일 가능성이 높음.
2. Pod만 죽은 경우: `kubectl delete pod eds-pg-1 -n cnpg` — 오퍼레이터가 같은 PVC로 자동 재생성.
   WAL replay로 커밋된 데이터까지 그대로 복구됨(오늘 테스트로 확인).
3. PVC까지 유실된 경우: **현재 백업이 없어 복구 불가.** 이 문서 작성 시점 기준 가장 시급한
   운영 개선 포인트 — Barman Cloud Plugin 또는 오브젝트 스토리지 연동한 `backup` 스펙을
   `cnpg-cluster.yaml`에 추가해야 함.
4. 데이터는 멀쩡한데 접속이 안 되는 경우: `eds-pg-rw` 서비스와 실제 Pod 라벨/엔드포인트 확인,
   Trino의 `postgresql.properties` 접속 정보(`connection-url`, user/password)가 바뀐 게 없는지 확인.

### Redis

1. `kubectl get pod -n redis redis-0` 로 상태 확인.
2. Pod만 재기동된 경우: AOF+RDB가 PVC(`/data`)에 있으므로 자동으로 복구됨 — 별도 조치 불필요
   (오늘 재기동 테스트로 확인).
3. `dump.rdb`/`appendonlydir`가 손상된 경우: 시작 로그에 로드 실패가 찍힌다. `redis-check-aof`,
   `redis-check-rdb`로 복구 시도. 안 되면 데이터 유실 감수하고 초기화.
4. 메모리 압박으로 최근 데이터가 안 보이는 경우(장애가 아니라 eviction): `INFO stats`의
   `evicted_keys` 값을 확인 — 0보다 크면 `maxmemory`를 늘리거나 정책을 재검토해야 함.
5. Trino에서 새 테이블이 안 보이면: `redis.table-description-dir`의 JSON 파일명/스키마 확인,
   **키 포맷이 `<schemaName>:<tableName>:<key>`가 아니라 `<tableName>:<key>`인지부터 확인**
   (오늘 이 문제로 한참 헤맸음 — `docs/` 내 관련 기록 참고).

### Ignite

1. `kubectl get pod -n ignite ignite-cluster-0` 로 상태 확인. `CrashLoopBackOff`면 반드시
   `kubectl logs`부터 확인 — discovery 클래스 로딩 실패, Spring bean 프로퍼티 오류 등
   설정 파일 문제일 확률이 높다(오늘 두 가지 다 겪음).
2. Pod는 떴는데 쿼리가 "Node in recovery mode"로 실패하는 경우: 정상적인 부팅 지연이니
   수십 초 정도 기다렸다가 재시도. 그래도 안 되면 로그에서 discovery join 실패 여부 확인.
3. **Persistence를 켠 상태에서 최초 활성화가 안 되는 경우**: `state=INACTIVE`가 로그에 찍히면
   `kubectl exec -n ignite ignite-cluster-0 -- /opt/ignite/apache-ignite/bin/control.sh --activate`
   로 수동 활성화. 이후 재기동부터는 baseline이 기억되어 자동 활성화됨.
4. PVC(`work-ignite-cluster-0`)가 살아있으면 데이터는 남아있다. 단, `ignite-config.xml`의
   `persistenceEnabled=false`인 상태로 되돌리면(또는 원래 그렇게 배포돼 있다면) 재기동 시
   **테이블 자체가 통째로 사라진다** — 버그가 아니라 순수 인메모리 설정의 당연한 결과이니
   장애 대응 전에 반드시 현재 persistence 설정부터 확인할 것.
5. ConfigMap을 고쳤는데 반영이 안 되는 것 같으면: StatefulSet의 `serviceName`이 ConfigMap과
   실제 배포본이 어긋나 있지 않은지 확인 — 어긋나 있으면 `kubectl apply`가 StatefulSet 부분만
   조용히 실패(Forbidden)하고 Pod는 계속 옛날 프로세스로 떠 있다가, 다음 재기동 때가 돼서야
   새 설정을 읽고 크래시하는 식으로 뒤늦게 터진다(오늘 실제로 이 순서로 장애가 남).

---

## 6. 결론

세 엔진 다 Trino에서 SQL로 보이긴 하지만 성격이 완전히 다르다. PostgreSQL은 가장 안정적이고 예측
가능하지만 백업이 빠져 있다는 게 지금 가장 큰 리스크다. Redis는 운영은 제일 편한데 Trino를 거치면
원래 강점(빠른 키 조회)을 못 살리고 오히려 셋 중 가장 느리며, eviction으로 조용히 데이터가
빠질 수 있다는 걸 계속 감시해야 한다. Ignite는 설정이 제일 까다롭고 오늘도 여러 번 문제가 났지만,
persistence를 제대로 켜두면 성능과 내구성을 동시에 챙길 수 있는 유일한 조합이다 — 다만 지금
아키텍처 의도(휘발성 hot buffer)와는 다른 용도로 쓰는 셈이니, 실제로 이렇게 운영할지는 별도로
결정해야 할 문제다.
