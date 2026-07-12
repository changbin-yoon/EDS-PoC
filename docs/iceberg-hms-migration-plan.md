# S3 원본 데이터 → Iceberg+S3(HMS) 이관 계획/절차

> 작성일: 2026-07-13
> 목적: S3에 있는 원본 데이터를 Iceberg+S3 테이블로 이 클러스터에 적재하는 절차.
> **테스트 목적으로 3개월치 데이터를 적재**하고, **하루 단위 마이그레이션은 Spark 작업으로
> 돌린다** — Trino는 마이그레이션(쓰기) 엔진이 아니라 결과물을 조회하는 쪽으로 역할을 맞췄다.
> 아직 실제로 실행하지 않은 **계획 단계** 문서다.

---

## 0. 확인이 필요한 것 (실행 전 결정 사항)

이 클러스터를 확인한 결과, 아직 다음이 없다:

- HMS(Hive Metastore) — 파드/네임스페이스/매니페스트 전부 없음
- Trino `iceberg`/`hive` 카탈로그
- Iceberg 전용 S3(MinIO) 버킷 — 지금 있는 건 `eds-pg-backup`(CNPG 백업용) 하나뿐
- Airflow — 없음 (지난번 메타정보 파이프라인 논의에서도 아직 미배포 상태였음)

반면 **Spark Operator는 이미 배포돼 있고 정상 동작 확인됨** (`operator-spark` 네임스페이스,
`spark-jobs`에 `word-count` 예제가 성공 완료된 이력 있음). `ScheduledSparkApplication` CRD도
설치돼 있어서, Airflow 없이도 K8s 네이티브로 크론 스케줄링이 가능하다 — 나중에 Airflow가
들어오면 그때 가서 DAG(`SparkKubernetesOperator`)로 갈아타면 된다.

| 결정 사항 | 옵션 A | 옵션 B |
|---|---|---|
| HMS 위치 | 이 클러스터에 새로 배포 (아래 절차 기준) | 이미 운영 중인 외부 HMS에 연결 — 1장 건너뛰고 `thrift://<host>:<port>` URI만 대입 |
| 원본 데이터 | 아직 없음 — MinIO에 3개월치 테스트 데이터부터 올리는 것부터 시작 | 이미 특정 버킷/경로에 있음 — 버킷명·경로·포맷을 알아야 정확한 스키마 매핑 가능 |
| 일별 마이그레이션 스케줄러 | `ScheduledSparkApplication`(K8s 네이티브, 지금 바로 가능) | Airflow가 들어오면 DAG + `SparkKubernetesOperator`로 전환 |

아래 절차는 **옵션 A(HMS 신규 배포) + `ScheduledSparkApplication`** 기준으로 썼다.

---

## 1. Hive Metastore 배포

HMS는 자체 메타데이터를 저장할 RDBMS가 필요하다. 이미 있는 CNPG(PostgreSQL) 클러스터에
`metastore`용 데이터베이스를 하나 추가해서 재사용하는 게 새 DB를 띄우는 것보다 간단하다.

1. CNPG `eds-pg` 클러스터에 `metastore` 데이터베이스 + 전용 유저 생성 (기존 `cnpg-eds-secret`
   패턴처럼 별도 Secret으로 자격증명 관리)
2. HMS를 Deployment로 배포 — standalone metastore 이미지 사용 (예: `apache/hive:4.0.0`을
   metastore 모드로, 또는 `tabulario/hive-metastore` — Trino+Iceberg+Spark 조합에서 흔히 쓰는
   이미지)
3. `hive-site.xml`에 설정할 항목:
   - `javax.jdo.option.ConnectionURL` → 1에서 만든 CNPG `metastore` DB (`eds-pg-rw` 서비스 경유)
   - `javax.jdo.option.ConnectionDriverName` → `org.postgresql.Driver`
   - `fs.s3a.endpoint` → `http://juicefs-minio.juicefs.svc.cluster.local:9000`
   - `fs.s3a.access.key` / `fs.s3a.secret.key` → 2장에서 만들 IAM 유저
   - `fs.s3a.path.style.access` → `true` (MinIO는 path-style 필요)
4. Service로 `thrift://<hms-service>.<ns>.svc.cluster.local:9083` 노출

이 HMS는 **Spark(쓰기)와 Trino(읽기) 둘 다 같은 카탈로그로 공유**한다 — 그래야 Spark가
써넣은 테이블을 Trino가 별도 등록 작업 없이 바로 본다.

---

## 2. S3 버킷 준비 (3개월치 테스트 데이터 기준)

전용 버킷 + 그 버킷에만 권한 있는 IAM 유저 패턴(`docs/airgap-full-test-runbook.md` 5-1 참고).

```bash
POD=<minio-pod>  # 이 클러스터에선 juicefs-minio-0
kubectl exec -n juicefs "$POD" -- mc mb local/raw-data          # 원본 3개월치
kubectl exec -n juicefs "$POD" -- mc mb local/iceberg-warehouse  # 이관 대상

kubectl exec -n juicefs "$POD" -- mc admin user add local iceberg-writer '<strong-password>'
# eds-pg-backup 때와 동일하게 두 버킷만 접근 가능한 정책 생성 후 attach
```

**원본 데이터 경로는 날짜별 파티션으로 올려두는 걸 권장**한다 (예:
`s3a://raw-data/events/dt=2026-07-01/`, `dt=2026-07-02/` ...) — 그래야 4장의 Spark 잡이
"오늘 파티션만" 골라 읽는 증분 처리가 자연스러워진다. 3개월치를 한 번에 다 밀어넣더라도,
이 파티션 구조는 유지해두는 게 이후 일별 마이그레이션 테스트와 맞아떨어진다.

---

## 3. Trino 카탈로그 추가 (조회 전용)

`trino/trino.yaml`의 `trino-catalog` ConfigMap에 `iceberg.properties` 하나만 추가한다 —
쓰기는 Spark가 담당하니 Trino 쪽엔 원본을 읽기 위한 `hive` 커넥터가 필수는 아니지만, 이관 전
원본 데이터를 눈으로 확인해보고 싶으면(검증용) 같이 추가해도 된다.

**`iceberg.properties`**:
```properties
connector.name=iceberg
iceberg.catalog.type=hive_metastore
hive.metastore.uri=thrift://<hms-service>.<ns>.svc.cluster.local:9083
fs.native-s3.enabled=true
s3.endpoint=http://juicefs-minio.juicefs.svc.cluster.local:9000
s3.path-style-access=true
s3.aws-access-key=iceberg-writer
s3.aws-secret-key=<2장에서 만든 비밀번호>
s3.region=us-east-1
```

기존 카탈로그들과 같은 방식으로 ConfigMap에 추가 → volumeMounts/volumes에도 마운트 추가 →
`kubectl apply` → coordinator 재시작.

---

## 4. 일별 마이그레이션 Spark 잡

### 4-1. Spark 쪽 Iceberg 설정

Spark 잡이 HMS를 카탈로그로 쓰도록 `spark-submit` 설정(또는 `SparkApplication` spec의
`sparkConf`)에 아래를 넣는다:

```properties
spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.iceberg.type=hive
spark.sql.catalog.iceberg.uri=thrift://<hms-service>.<ns>.svc.cluster.local:9083
spark.sql.catalog.iceberg.warehouse=s3a://iceberg-warehouse/
spark.hadoop.fs.s3a.endpoint=http://juicefs-minio.juicefs.svc.cluster.local:9000
spark.hadoop.fs.s3a.access.key=iceberg-writer
spark.hadoop.fs.s3a.secret.key=<비밀번호>
spark.hadoop.fs.s3a.path.style.access=true
```

`iceberg-spark-runtime` jar(Spark/Iceberg 버전에 맞는 것)를 `spark.jars.packages` 또는
이미지에 포함시켜야 한다.

### 4-2. 잡 로직 (의사코드)

```python
target_date = ...  # 실행일 기준 D-1, 파라미터로 받음

df = spark.read.format("csv")  # 원본 포맷에 맞게
    .load(f"s3a://raw-data/events/dt={target_date}/")

df.writeTo("iceberg.target_schema.target_table") \
  .append()   # 최초 1회는 .create(), 이후엔 .append() — 또는 파티션 덮어쓰기면 overwritePartitions()
```

날짜 파티션 하루치만 읽어서 Iceberg 테이블에 append하는 구조 — 2장에서 원본을 날짜별로
올려두라고 한 이유가 이거다.

### 4-3. `ScheduledSparkApplication`으로 매일 실행

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: ScheduledSparkApplication
metadata:
  name: daily-iceberg-migration
  namespace: spark-jobs
spec:
  schedule: "0 1 * * *"   # 매일 새벽 1시
  concurrencyPolicy: Forbid   # 전날 작업이 안 끝났으면 새로 안 띄움
  template:
    type: Python
    mode: cluster
    image: <iceberg-spark-runtime 포함된 이미지>
    mainApplicationFile: local:///opt/spark/jobs/daily_migration.py
    arguments: ["{{ds}}"]   # 또는 잡 내부에서 date.today() - 1day로 계산
    sparkConf:
      spark.sql.catalog.iceberg: org.apache.iceberg.spark.SparkCatalog
      # ... 4-1의 나머지 설정
```

`word-count` 예제(`spark/spark-word-count.yaml`)가 이미 `SparkApplication` 배포 패턴을
보여주고 있으니, 그 파일을 참고해서 `image`/리소스 설정 부분만 맞추면 된다.

---

## 5. 3개월치 초기 적재 (백필)

일별 잡을 매일 도는 것과 별개로, 테스트를 시작하려면 과거 3개월치를 한 번에 밀어넣어야 한다.
이건 4-2 로직을 날짜 루프로 감싼 **일회성 백필 잡**으로 처리한다 — `ScheduledSparkApplication`이
아니라 그냥 `SparkApplication`(1회성)으로:

```python
from datetime import date, timedelta

start = date.today() - timedelta(days=90)
for i in range(90):
    d = start + timedelta(days=i)
    df = spark.read.format("csv").load(f"s3a://raw-data/events/dt={d}/")
    df.writeTo("iceberg.target_schema.target_table").append()
```

날짜별로 나눠서 append하는 이유는, 나중에 특정 날짜만 재처리해야 할 때(데이터 오류 등)
Iceberg의 파티션 단위 `overwritePartitions()`로 그 날짜만 골라 다시 쓸 수 있게 하기 위해서다 —
한 번에 3개월치를 통짜로 밀어넣으면 이후 특정 날짜만 고치기 어려워진다.

---

## 6. 검증 (Trino로 조회)

```sql
SELECT count(*) FROM iceberg.target_schema.target_table;

-- 날짜별 파티션이 제대로 나뉘어 들어갔는지
SELECT dt, count(*) FROM iceberg.target_schema.target_table GROUP BY dt ORDER BY dt;

SHOW CREATE TABLE iceberg.target_schema.target_table;
```

3개월(90일) 분량이면 `dt`별 그룹 개수가 90줄 나와야 정상.

---

## 주의할 점 (이번 세션 교훈과 연결)

- **왜 Trino CTAS가 아니라 Spark로 마이그레이션을 하는지**: 이번 세션에서 Trino의 일반
  `INSERT`가 대량 데이터에 너무 느려서(46K행에서도 coordinator OOM) 매번 네이티브 벌크로드로
  우회했던 것과 같은 이유다 — Trino 엔진을 거치는 쓰기는 매 행을 직렬화/역직렬화하는 비용이
  붙는다. 3개월치(파일 크기에 따라 다르지만 수백만~수천만 행 규모일 수 있음)를 Trino로
  밀어넣으면 같은 문제를 또 겪을 가능성이 높다 — 그래서 이번엔 처음부터 Spark를 마이그레이션
  엔진으로 잡았다. Trino는 결과를 빠르게 조회하는 역할만 맡는다.
- **날짜 파티션 구조를 처음부터 잡아둘 것** — 나중에 "1일 지난 데이터만 삭제/이관" 같은
  운영(`docs/airflow-metadata-pipeline-design.md`에서 다룬 hot/cold 이관 패턴)을 하려면
  파티션 단위 연산이 훨씬 깔끔하다. 통짜 테이블로 넣어두면 나중에 후회한다.
- **MinIO 자격증명은 버킷별로 분리** — `raw-data`, `iceberg-warehouse`, 기존 `eds-pg-backup`
  전부 별도 IAM 유저 + 해당 버킷 전용 정책. 같은 root 자격증명으로 몰아 쓰지 말 것.
- **HMS 리소스**: 지금 클러스터 워커 노드 사용률은 낮은 편이라(6~24%) 여유는 있지만, HMS +
  Spark 드라이버/이그제큐터 파드까지 새로 뜨면서 리소스가 늘어나니 배포 후 `kubectl top` 확인
  권장.
- **일회성 백필과 매일 도는 잡의 Iceberg 쓰기 모드를 구분할 것** — 최초 테이블 생성은
  `.create()` 또는 `.createOrReplace()`, 이후 매일은 `.append()`. 스케줄된 잡이 실수로
  `.create()`를 매번 호출하면 기존 데이터를 날려버리니 로직에서 명확히 분리해야 한다.
