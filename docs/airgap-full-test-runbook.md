# Airgap 환경 전체 재현 절차서 (Ignite / PostgreSQL / Redis + Trino)

> 이 문서만 보고 외부 도움 없이 처음부터 끝까지 재현할 수 있도록 작성했다.
> 실제로 이 저장소 내용을 가지고 한 번 전체 재현해서 검증한 절차 그대로다.
> 명령어는 전부 리포지토리 루트(`EDS-PoC/`)에서 실행하는 것을 기준으로 한다.
>
> **Redis 관련 주의**: 배포(1장)와 백업(6장)에는 여전히 Redis가 포함돼 있지만, **성능
> 테스트/대량 적재 스크립트(4장, 9장)에서는 Redis를 의도적으로 제외**했다. 이유는
> `docs/lessons-learned.md` 2-1장 참고 — 요약하면 Trino의 Redis 커넥터는 서버사이드
> 필터링이 없어 모든 쿼리가 풀스캔이 되고, 실측으로도 항상 가장 느렸다.
>
> **결과/원인 분석은 별도 문서**: 이 문서는 순수 절차서다. 실측 수치는
> `docs/test-results-summary.md`, 버그·아키텍처 통찰은 `docs/lessons-learned.md` 참고.

---

## 0. 사전 준비 (Airgap 특화)

### 0-1. 필요한 컨테이너 이미지 목록

아래 이미지들을 airgap 반입 전에 미리 받아서(`docker pull` → `docker save`) 사내 레지스트리로
옮기거나 tar로 반입해야 한다. 반입 후에는 각 YAML의 `image:` 값을 사내 레지스트리 주소로
바꿔야 한다(예: `docker.io/library/redis:7-alpine` → `registry.internal/redis:7-alpine`).

| 용도 | 이미지 |
|---|---|
| Trino | `trinodb/trino:481` |
| Ignite | `apacheignite/ignite:2.18.0` |
| Redis | `redis:7-alpine` |
| CNPG 오퍼레이터 | `ghcr.io/cloudnative-pg/cloudnative-pg:1.29.1` |
| PostgreSQL (CNPG가 내부적으로 사용) | `ghcr.io/cloudnative-pg/postgresql:18.3-system-trixie` |
| Ingress (Trino UI 노출용) | `registry.k8s.io/ingress-nginx/controller:v1.15.1` |
| MinIO (PostgreSQL 백업 대상, 사내에 S3 호환 스토리지가 이미 있으면 불필요) | `quay.io/minio/minio:RELEASE.2024-10-13T13-34-11Z` |

> CNPG는 `Cluster` CR을 적용하면 오퍼레이터가 postgres 이미지를 자동으로 pull하려 시도한다.
> airgap에서는 `spec.imageName`으로 사내 레지스트리 주소를 명시해야 한다
> (`cnpg/cnpg-cluster.yaml`의 `spec.instances` 근처에 `imageName: registry.internal/postgresql:18.3-...` 추가).

### 0-2. 필요한 도구

- `kubectl` (클러스터 접근 가능한 kubeconfig)
- `python3` (표준 라이브러리만 사용, 추가 패키지 설치 불필요 — `pandas` 등 없어도 동작)
- `bc` (성능 테스트 스크립트에서 시간 계산에 사용 — 없으면 `sudo apt install bc` 등으로 설치)
- Ingress를 실제로 브라우저에서 접근하려면 `*.<클러스터도메인>` 와일드카드 DNS 등록 (airgap 사내 DNS)

### 0-3. 스토리지클래스 확인

이 저장소의 모든 PVC는 `csi-cinder-sc-retain`(OpenStack Cinder CSI)을 가정한다. airgap 환경의
스토리지클래스 이름이 다르면 `ignite/ignite.yaml`, `redis/redis.yaml`, `cnpg/cnpg-cluster.yaml`
세 파일에서 `storageClassName`/`storageClass` 값을 전부 바꿔야 한다.

```bash
kubectl get storageclass
```

---

## 1. 배포

순서가 중요하다. Ignite가 Trino보다 먼저 떠 있어야 카탈로그 연결이 바로 된다.

```bash
export KUBECONFIG=<your-kubeconfig>

# 1) PostgreSQL (CNPG 오퍼레이터가 먼저 설치돼 있어야 함 — operators/ 참고)
kubectl apply -f operators/
kubectl apply -f cnpg/cnpg-cluster.yaml
kubectl wait --for=condition=Ready cluster/eds-pg -n cnpg --timeout=180s

# 2) Redis
kubectl apply -f redis/redis.yaml
kubectl wait --for=condition=Ready pod -l app=redis -n redis --timeout=120s

# 3) Ignite
kubectl apply -f ignite/ignite.yaml
kubectl wait --for=condition=Ready pod -l app=ignite -n ignite --timeout=180s
# 최초 1회, persistence를 처음 켜는 시점에는 자동 활성화가 안 될 수 있다 (아래 4-1 참고).

# 4) Trino
kubectl apply -f trino/trino.yaml
kubectl wait --for=condition=Ready pod -l app=trino -n trino --timeout=120s
```

배포 직후 카탈로그가 다 보이는지 확인:

```bash
COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n trino "$COORD" -- trino --execute "SHOW CATALOGS;"
# ignite / postgresql / redis / system 이 나와야 함
```

### 1-1. Ignite persistence 최초 활성화

`ignite/ignite.yaml`은 `persistenceEnabled=true`로 설정돼 있다. **최초 1회만** 수동 활성화가 필요하다
(이후 재기동부터는 자동):

```bash
kubectl logs -n ignite ignite-cluster-0 | grep "state=" | tail -1
# state=INACTIVE 이면:
kubectl exec -n ignite ignite-cluster-0 -- /opt/ignite/apache-ignite/bin/control.sh --activate
```

---

## 2. 테스트 데이터 생성 및 적재

`sample/` 폴더의 CSV 10개(OMOP CDM 샘플)를 세 엔진에 동일하게 넣는다.

```bash
# SQL/HSET 파일 생성 (컬럼 타입은 CSV 값을 보고 자동 추론됨)
python3 scripts/generate-test-data.py --out-dir /tmp/eds-poc-gen

# 생성된 파일을 세 엔진에 적재
export KUBECONFIG=<your-kubeconfig>
./scripts/load-test-data.sh /tmp/eds-poc-gen
```

`load-test-data.sh`가 하는 일 (내부적으로):
1. 생성된 `*.redis.json`으로 `trino-redis-tables` ConfigMap을 통째로 재생성하고 Trino coordinator 재시작
2. 각 테이블을 Ignite/PostgreSQL에 `CREATE TABLE` + 배치 `INSERT` (Trino 경유)
3. 각 테이블을 Redis에 `HSET` (redis-cli 직접, Trino는 Redis에 쓰기를 지원하지 않음)

### 검증

```bash
./scripts/verify-row-counts.sh /tmp/eds-poc-gen
```

세 엔진 다 같은 행 수가 나와야 정상이다. 안 맞으면 아래 8장 트러블슈팅부터 확인.

---

## 3. 재기동/휘발성(persistence) 테스트

세 엔진의 재기동 내구성 차이를 직접 확인하는 절차. (배경: Redis/Ignite는 "인메모리 DB"라
불리지만 내구성은 persistence 설정에 달려있다 — `docs/lessons-learned.md` 2-3장 참고)

```bash
# 재기동 전 행 수 기록
./scripts/verify-row-counts.sh /tmp/eds-poc-gen

# 세 Pod 강제 재기동
kubectl delete pod ignite-cluster-0 -n ignite
kubectl delete pod redis-0 -n redis
kubectl delete pod eds-pg-1 -n cnpg   # 실제 pod 이름은 `kubectl get pod -n cnpg`로 확인

# 전부 Ready 될 때까지 대기
kubectl wait --for=condition=Ready pod -l app=ignite -n ignite --timeout=180s
kubectl wait --for=condition=Ready pod -l app=redis -n redis --timeout=120s
kubectl wait --for=condition=Ready pod -n cnpg -l cnpg.io/cluster=eds-pg --timeout=180s

# 재기동 후 행 수 재확인 — persistence가 제대로 켜져 있으면 세 엔진 다 데이터 유지되어야 함
./scripts/verify-row-counts.sh /tmp/eds-poc-gen
```

**만약 `ignite.yaml`의 `persistenceEnabled`를 `false`로 바꿔서 테스트해보면** (원래 이 데이터셋이
설계된 "Kafka hot buffer" 모드), Ignite만 재기동 후 테이블 자체가 사라지는 걸 확인할 수 있다 —
이건 버그가 아니라 설계상 당연한 결과다. 자세한 원인은 `docs/lessons-learned.md` 2-3장 참고.

---

## 4. 성능 테스트

```bash
export KUBECONFIG=<your-kubeconfig>
./scripts/perf-test.sh | tee perf-results-$(date +%Y%m%d).txt
```

`measurement` 테이블(46,216행) 기준으로 6가지 쿼리(전체 카운트, 비인덱스 필터, PK 조회,
GROUP BY 집계, JOIN, 반복 실행)를 세 카탈로그에 대해 순서대로 실행하고 wall-clock 시간을 출력한다.

**측정값 해석 시 주의**: 매 쿼리마다 `kubectl exec` + Trino CLI 기동 오버헤드(약 1.3~1.5초)가
고정으로 들어간다. 따라서 **절대 시간보다 세 엔진 간 상대적인 차이**를 보는 것이 의미 있다.
기존 실행 결과(참고용, 환경에 따라 달라질 수 있음)는 `docs/test-results-summary.md` 1장 참고.

---

## 5. PostgreSQL 백업/복구

### 5-1. 백업 대상 스토리지 준비

`cnpg/cnpg-cluster.yaml`의 `spec.backup.barmanObjectStore`는 S3 호환 오브젝트 스토리지가 필요하다.
airgap에 이미 사내 S3 호환 스토리지(MinIO 등)가 있으면 그 정보로, 없으면 새로 하나 띄워야 한다.

이 프로젝트를 테스트한 클러스터에서는 이미 떠 있던 MinIO(JuiceFS용, `juicefs` 네임스페이스)를
재사용했다 — 전용 버킷과 그 버킷에만 권한 있는 IAM 유저를 새로 만드는 방식:

```bash
# MinIO 관리자 자격증명으로 mc 클라이언트 alias 설정 (파드 내부에서 mc 사용)
kubectl exec -n <minio-namespace> <minio-pod> -- mc alias set local http://localhost:9000 <root-user> <root-password>

# 백업 전용 버킷 생성
kubectl exec -n <minio-namespace> <minio-pod> -- mc mb local/eds-pg-backup

# 백업 전용 IAM 유저 + 그 버킷만 접근 가능한 정책 생성
kubectl exec -n <minio-namespace> <minio-pod> -- mc admin user add local cnpg-backup '<strong-password>'
cat > /tmp/policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::eds-pg-backup", "arn:aws:s3:::eds-pg-backup/*"] }
  ]
}
EOF
kubectl cp /tmp/policy.json <minio-namespace>/<minio-pod>:/tmp/policy.json
kubectl exec -n <minio-namespace> <minio-pod> -- mc admin policy create local cnpg-backup-policy /tmp/policy.json
kubectl exec -n <minio-namespace> <minio-pod> -- mc admin policy attach local cnpg-backup-policy --user cnpg-backup
```

### 5-2. CNPG 백업 설정 반영

`cnpg/cnpg-cluster.yaml`에 이미 아래 내용이 들어가 있다 — airgap 환경에서는 `endpointURL`과
`cnpg-backup-s3-creds` 시크릿 값만 실제 환경에 맞게 바꾸면 된다.

```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://eds-pg-backup/eds-pg
      endpointURL: http://<minio-service>.<namespace>.svc.cluster.local:9000
      s3Credentials:
        accessKeyId: { name: cnpg-backup-s3-creds, key: ACCESS_KEY_ID }
        secretAccessKey: { name: cnpg-backup-s3-creds, key: ACCESS_SECRET_KEY }
      wal:
        compression: gzip
    retentionPolicy: "7d"
```

> **참고**: CNPG 1.29.1 기준 이 방식(`barmanObjectStore` in-tree)은 deprecated 경고가 뜨지만
> 1.30.0 전까지는 계속 동작한다. 이후 버전으로 올릴 계획이면 Barman Cloud Plugin으로 마이그레이션이
> 필요하다 — 플러그인은 별도 오퍼레이터/이미지가 필요해서 airgap 이미지 목록에 추가해야 함.

적용 후 확인:

```bash
kubectl apply -f cnpg/cnpg-cluster.yaml
kubectl get cluster -n cnpg eds-pg -o jsonpath='{.status.conditions}' | grep -A2 ContinuousArchiving
# "Continuous archiving is working" 이 나오면 WAL 아카이빙 정상
```

### 5-3. 수동 백업 트리거 + 검증

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: eds-pg-manual-backup
  namespace: cnpg
spec:
  cluster:
    name: eds-pg
EOF

kubectl get backup -n cnpg eds-pg-manual-backup -w
# phase: completed 확인

# 실제로 오브젝트 스토리지에 파일이 생겼는지 확인
kubectl exec -n <minio-namespace> <minio-pod> -- mc ls --recursive local/eds-pg-backup
```

### 5-4. 스케줄 백업

`cnpg/cnpg-cluster.yaml`에 매일 새벽 3시 전체 백업(`ScheduledBackup`)이 이미 포함되어 있다.
운영 시간에 맞춰 `spec.schedule` 크론 표현식만 조정하면 된다.

### 5-5. 복구 (재해복구 시나리오)

```bash
# 새 Cluster를 백업으로부터 부트스트랩 (원본 클러스터가 완전히 사라진 경우)
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: eds-pg-restored
  namespace: cnpg
spec:
  instances: 1
  storage:
    size: 10Gi
    storageClass: csi-cinder-sc-retain
  bootstrap:
    recovery:
      source: eds-pg
  externalClusters:
    - name: eds-pg
      barmanObjectStore:
        destinationPath: s3://eds-pg-backup/eds-pg
        endpointURL: http://<minio-service>.<namespace>.svc.cluster.local:9000
        s3Credentials:
          accessKeyId: { name: cnpg-backup-s3-creds, key: ACCESS_KEY_ID }
          secretAccessKey: { name: cnpg-backup-s3-creds, key: ACCESS_SECRET_KEY }
EOF
```

백업 검증 결과(실제로 MinIO에 파일이 쌓이는 것까지 확인한 내역)는 `docs/test-results-summary.md`
3장 참고. 복구(`eds-pg-restored`) 자체는 별도 인스턴스를 새로 띄우는 것이라 이번 세션에서는
실행하지 않았음 — airgap 재현 시 한 번 직접 검증해볼 것을 권장한다.

---

## 6. Redis 백업/복구

Redis는 별도 오브젝트 스토리지 없이 PVC(`/data`)에 AOF+RDB로 이미 영속화되고 있다
(`redis.conf`의 `appendonly yes`).

- **정기 백업**: `redis-cli -a edsuser123 BGSAVE`로 RDB 스냅샷 강제 생성 → `/data/dump.rdb`를
  cron이나 K8s CronJob으로 별도 스토리지에 복사.
- **복구**: 새 Pod가 같은 PVC를 마운트하면 시작 시 자동으로 AOF/RDB를 읽어 복구한다(재기동
  테스트로 이미 확인). PVC 자체가 유실된 경우엔 백업해둔 `dump.rdb`를 새 PVC의 `/data`에
  넣고 Pod를 기동하면 됨.

---

## 7. Ignite 백업/복구

Ignite도 native persistence(PVC의 `/opt/ignite/work`)로 재기동 시 복구되는 것을 확인했다.
추가로 시점 스냅샷이 필요하면:

```bash
kubectl exec -n ignite ignite-cluster-0 -- /opt/ignite/apache-ignite/bin/control.sh --snapshot create <snapshot-name>
```

스냅샷은 `/opt/ignite/work/snapshots`에 저장된다 — PVC 자체가 백업 대상이므로, 이 경로를
포함해 PVC 스냅샷(CSI VolumeSnapshot)을 주기적으로 뜨는 것을 권장.

---

## 8. 트러블슈팅

실제로 겪은 문제와 원인·해결책은 전부 `docs/lessons-learned.md` 1장(배포/설정 버그 표)에
정리해뒀다. 여기서는 중복 없이 그 문서를 참고하는 것으로 대신한다 — 증상이 발생하면 그 표에서
먼저 찾아볼 것.

---

## 9. 대용량(수백만 건) 합성 데이터 테스트

OMOP 샘플 CSV가 아니라 **직접 정의한 컬럼/타입으로 임의 데이터를 대량 생성**해서 테스트하고
싶을 때 쓰는 절차. 자세한 배경과 실측 결과는 `docs/test-results-summary.md` 참고.

```bash
# 1) 스키마 정의 (scripts/schema-example.json을 복사해서 컬럼 구성 변경)
cp scripts/schema-example.json /tmp/my-schema.json
# ... 컬럼/타입/생성규칙 편집 (파일 상단 docstring에 gen 전략 설명 있음) ...

# 2) 데이터 생성 (표준 라이브러리만 사용 — airgap에서 pip install 불필요)
python3 scripts/generate-synthetic-data.py \
  --schema /tmp/my-schema.json --rows 9000000 --out /tmp/synthetic.csv --seed 42

# 3) PVC 용량 확인/증설 (대량 데이터 전에 미리)
kubectl patch cluster eds-pg -n cnpg --type merge -p '{"spec":{"storage":{"size":"20Gi"}}}'
kubectl patch pvc work-ignite-cluster-0 -n ignite -p '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'

# 4) 네이티브 벌크로드 (Trino INSERT가 아니라 psql \copy / Ignite COPY 사용 — 훨씬 빠름)
./scripts/bulk-load-postgresql.sh /tmp/synthetic.csv
./scripts/bulk-load-ignite.sh /tmp/synthetic.csv

# 5) 성능 테스트 (테이블명, PK 컬럼, GROUP BY용 컬럼을 스키마에 맞게 지정)
./scripts/perf-test.sh iot_events event_id device_id
```

실측 결과(적재 속도, 스토리지, 성능, `query_parallelism` 튜닝 전/후 비교)는
`docs/test-results-summary.md` 4장 참고.

### Ignite 쿼리 병렬도(`query_parallelism`) 튜닝

Trino `CREATE TABLE`로 만든 Ignite 테이블은 `query_parallelism`이 기본값 1로 생성된다 —
GROUP BY처럼 전체 행을 훑어야 하는 쿼리에서 단일 스레드로만 처리되어 느려질 수 있다
(자세한 진단 경위는 `docs/lessons-learned.md` 2-4장). 파드에 할당된 CPU limit에 맞춰
재생성하는 걸 권장:

```bash
# 1) 기존 테이블 삭제 (Trino 경유)
COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n trino "$COORD" -- trino --execute "DROP TABLE IF EXISTS ignite.public.<table>;"

# 2) Ignite 네이티브 SQL로 parallelism 지정해서 재생성 (컬럼 정의는 <csv>.ignite.create.sql 참고)
IGNITE_POD=$(kubectl get pod -n ignite -l app=ignite -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ignite "$IGNITE_POD" -- /opt/ignite/apache-ignite/bin/sqlline.sh \
  -u "jdbc:ignite:thin://127.0.0.1:10800/" -n ignite -p ignite --connectInteractionMode=notAskCredentials \
  -e "CREATE TABLE PUBLIC.<TABLE> (... , PRIMARY KEY (...)) WITH \"template=partitioned,backups=0,parallelism=<CPU_LIMIT>\";"

# 3) 데이터 재적재 (bulk-load-ignite.sh는 테이블이 이미 있으면 CREATE는 건너뛰고 COPY만 실행됨)
./scripts/bulk-load-ignite.sh /tmp/synthetic.csv
```

`<CPU_LIMIT>`은 `kubectl get statefulset ignite-cluster -n ignite -o jsonpath='{...resources.limits.cpu}'`로
확인한 실제 cgroup 할당량을 쓸 것 — 컨테이너 안에서 `nproc`으로 보이는 값은 host 전체 코어 수라
오해하기 쉽다.

---

## 10. Trino Kafka 카탈로그 연결 (참고 — 분석 쿼리 용도로는 비권장)

Kafka 토픽을 Trino에서 SQL로 조회할 수 있게 연결하는 절차. **성능 테스트 결과 분석 쿼리
용도로는 부적합**하다(모든 쿼리가 토픽 전체 소비 — `docs/lessons-learned.md` 2-10장 참고).
"토픽에 지금 뭐가 들었는지" SQL로 잠깐 들여다보는 임시 탐색/디버깅 용도로만 쓸 것.

전제: Strimzi Kafka 클러스터가 `kafka` 네임스페이스에 떠 있음
(bootstrap: `my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092`, 파드 `my-cluster-dual-role-0`).
airgap 이미지 목록에 Strimzi 오퍼레이터/Kafka 이미지는 별도 반입 필요 (이 저장소 범위 밖).

### 10-1. trino.yaml에 이미 들어있는 것

`trino/trino.yaml`에 아래 세 가지가 반영돼 있다 — 다른 토픽을 붙이려면 이 부분을 수정:

1. `trino-catalog` ConfigMap의 `kafka.properties` — `kafka.nodes`(bootstrap 주소),
   `kafka.table-names=default.device_events`(노출할 토픽 목록, 쉼표 구분으로 추가)
2. `trino-kafka-tables` ConfigMap — 토픽별 JSON 테이블 정의(`device_events.json` 참고:
   `topicName`, message `dataFormat: json`, 컬럼→JSON 필드 매핑). Redis의
   `trino-redis-tables`와 같은 방식
3. Deployment의 volume/volumeMount — `kafka.properties`와 `/etc/trino/kafka-tables` 마운트

적용 후 Trino 재시작이 필요하다:

```bash
kubectl apply -f trino/trino.yaml
kubectl rollout restart deployment/trino-coordinator -n trino
kubectl rollout status deployment/trino-coordinator -n trino
```

### 10-2. 테스트 메시지 대량 적재

메시지를 한 건씩 넣지 말고 newline-delimited JSON 파일로 만들어 한 번에 파이프로 넣는다:

```bash
# 1) 로컬에서 10만 건 생성
python3 -c "
import json, random
random.seed(42)
types = ['TEMP', 'HUMIDITY', 'PRESSURE']
with open('/tmp/kafka_msgs.json', 'w') as f:
    for _ in range(100000):
        f.write(json.dumps({'device_id': random.randint(1, 50000),
                            'event_type': random.choice(types),
                            'value': round(random.uniform(0, 100), 2)}) + '\n')
"

# 2) Kafka 파드로 복사 — 반드시 데이터 PVC 경로로! (/tmp는 5MB tmpfs라 잘림)
kubectl cp /tmp/kafka_msgs.json kafka/my-cluster-dual-role-0:/var/lib/kafka/data-0/kafka_msgs.json -c kafka

# 3) 한 번에 produce 후 스테이징 파일 삭제
kubectl exec -n kafka my-cluster-dual-role-0 -c kafka -- bash -c \
  'bin/kafka-console-producer.sh --topic device_events --bootstrap-server localhost:9092 \
     < /var/lib/kafka/data-0/kafka_msgs.json && rm /var/lib/kafka/data-0/kafka_msgs.json'

# 4) 적재 건수 확인 (파티션별 offset 합계가 총 메시지 수)
kubectl exec -n kafka my-cluster-dual-role-0 -c kafka -- \
  bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic device_events
```

### 10-3. Trino에서 조회

```bash
COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n trino "$COORD" -- trino --execute \
  "SELECT event_type, count(*) FROM kafka.default.device_events GROUP BY event_type;"
```

어떤 쿼리든(결과가 몇 행이든) 토픽 전체를 소비하므로, 토픽이 커질수록 정비례로 느려진다는
점을 감안할 것. 실측 수치는 `docs/test-results-summary.md` 10장.

---

## 11. 결과 정리 방법

성능 지표를 뽑았으면 `docs/test-results-summary.md`의 표 형식을 그대로 참고해서 자신의 환경
결과로 갱신하면 된다. 절대 수치는 환경(노드 스펙, 네트워크)마다 다르게 나올 수 있으니, 이 문서의
수치와 비교할 땐 상대적인 순위(어떤 엔진이 어떤 쿼리 유형에서 유리한가) 위주로 보는 것을 권장한다.
