# CloudNativePG (CNPG) PostgreSQL 클러스터 배포 가이드

## 개요

| 항목 | 값 |
|---|---|
| 오퍼레이터 | CloudNativePG (`postgresql.cnpg.io/v1`) |
| 클러스터 이름 | `eds-pg` |
| 네임스페이스 | `cnpg` |
| 인스턴스 수 | 1 (단일 프라이머리) |
| 데이터베이스 | `eds` |
| 소유 유저 | `eds` / `edsuser123` |
| 저장소 | `csi-cinder-sc-retain` 10Gi |

## 사전 요구사항

CloudNativePG **오퍼레이터**가 클러스터에 설치되어 있어야 한다.
오퍼레이터는 `cnpg-system` 네임스페이스에 상주하며 `Cluster` CRD를 제공한다.

```bash
# 오퍼레이터 설치 확인
kubectl get deployment -n cnpg-system cnpg-controller-manager

# 미설치 시
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
```

## 파일 구성

```
cnpg/
├── cnpg-cluster.yaml   # Namespace, Secret, Cluster 전체
└── README.md
```

## 아키텍처

### CNPG가 자동 생성하는 리소스

| 리소스 | 이름 | 용도 |
|---|---|---|
| Pod | `eds-pg-1` | PostgreSQL 프라이머리 인스턴스 |
| PVC | `eds-pg-1` | 데이터 저장 (10Gi, Retain 정책) |
| Service | `eds-pg-rw` | 읽기/쓰기 (프라이머리 연결) |
| Service | `eds-pg-ro` | 읽기 전용 (스탠바이 연결, 단일 노드 시 프라이머리 가리킴) |
| Service | `eds-pg-r` | 임의 인스턴스 (부하분산) |
| Secret | `eds-pg-app` | 앱 유저 비밀번호 (CNPG 자동 생성) |
| Secret | `eds-pg-ca` | CA 인증서 |
| Secret | `eds-pg-server` | 서버 TLS 인증서 |
| Secret | `eds-pg-replication` | 복제 TLS 인증서 |

### 클라이언트 접속 주소

| 목적 | 주소 |
|---|---|
| 읽기/쓰기 (Trino, 앱 연결) | `eds-pg-rw.cnpg.svc.cluster.local:5432` |
| 읽기 전용 | `eds-pg-ro.cnpg.svc.cluster.local:5432` |
| 클러스터 내부 직접 접속 | `eds-pg-1.cnpg.svc.cluster.local:5432` |

### Bootstrap Secret 역할

`cnpg-eds-secret`은 클러스터 **최초 생성 시에만** 사용된다.
이후 비밀번호 변경은 `eds-pg-app` Secret 또는 SQL로 직접 수행해야 한다.

```bash
# 현재 비밀번호 확인 (CNPG 자동 생성 secret)
kubectl get secret -n cnpg eds-pg-app -o jsonpath='{.data.password}' | base64 -d
```

## 배포

```bash
kubectl apply -f cnpg/cnpg-cluster.yaml
```

**클러스터 Ready 대기** (initdb 포함 약 1-2분)

```bash
until kubectl get cluster -n cnpg eds-pg \
  -o jsonpath='{.status.readyInstances}' 2>/dev/null | grep -q 1
do sleep 3; done
kubectl get cluster -n cnpg eds-pg
```

**정상 기동 확인**

```bash
kubectl get cluster,pod,svc,pvc -n cnpg
```

출력 예:
```
NAME                                AGE   INSTANCES   READY   STATUS   PRIMARY
cluster.postgresql.cnpg.io/eds-pg   5m    1           1       Cluster in healthy state   eds-pg-1

NAME        READY   STATUS    RESTARTS   AGE
pod/eds-pg-1   1/1   Running   0          5m

NAME           TYPE        CLUSTER-IP   PORT(S)    AGE
service/eds-pg-r    ClusterIP   ...   5432/TCP   5m
service/eds-pg-ro   ClusterIP   ...   5432/TCP   5m
service/eds-pg-rw   ClusterIP   ...   5432/TCP   5m
```

## 검증

### Pod 내부에서 psql 접속

```bash
kubectl exec -it -n cnpg eds-pg-1 -- psql -U eds eds
```

psql 내부:
```sql
\dt             -- 테이블 목록
SELECT version();
\q
```

### Trino에서 접속 확인

```bash
COORD=$(kubectl get pod -n trino -l component=coordinator \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n trino $COORD -- trino --execute "SHOW SCHEMAS FROM postgresql;"
# 예상 출력: information_schema / pg_catalog / public
```

### SQL 테스트 (Trino 경유)

```sql
-- 테이블 생성
CREATE TABLE postgresql.public.sample (
  id   INTEGER,
  name VARCHAR
);

-- 데이터 삽입/조회
INSERT INTO postgresql.public.sample VALUES (1, 'test');
SELECT * FROM postgresql.public.sample;
```

## 운영 명령어

```bash
# 클러스터 상태 확인
kubectl get cluster -n cnpg eds-pg

# Pod 로그 확인
kubectl logs -n cnpg eds-pg-1

# 설정 변경 후 적용 (재시작 없이 반영)
kubectl apply -f cnpg/cnpg-cluster.yaml

# psql 직접 접속
kubectl exec -it -n cnpg eds-pg-1 -- psql -U eds eds

# 비밀번호 변경 (SQL)
kubectl exec -it -n cnpg eds-pg-1 -- psql -U eds eds \
  -c "ALTER USER eds WITH PASSWORD 'newpassword';"
```

## 인스턴스 수 스케일아웃

`instances: 1` → `instances: 2` 로 변경하면 스탠바이 1개가 추가된다.
CNPG가 자동으로 streaming replication을 구성하며, 프라이머리 장애 시 자동 failover된다.

```yaml
spec:
  instances: 2   # primary 1 + standby 1
```

```bash
kubectl apply -f cnpg/cnpg-cluster.yaml
kubectl get cluster -n cnpg eds-pg --watch
```

## 삭제

```bash
# 클러스터 삭제 (PVC는 retain 정책으로 보존)
kubectl delete -f cnpg/cnpg-cluster.yaml

# PVC 포함 완전 삭제 (데이터 소실 주의)
kubectl delete pvc -n cnpg eds-pg-1
```

## SealedSecret 전환 권장

현재 `cnpg-eds-secret`은 평문 Secret이다.
운영 환경에서는 Sealed Secrets로 암호화 관리를 권장한다:

```bash
kubectl create secret generic cnpg-eds-secret -n cnpg --dry-run=client \
  --from-literal=username=eds \
  --from-literal=password=edsuser123 -o yaml | \
  kubeseal --controller-name=sealed-secrets \
           --controller-namespace=kube-system \
           --format yaml > cnpg/cnpg-eds-sealedsecret.yaml
```

그 후 `cnpg-cluster.yaml`에서 Secret 부분을 제거하고 SealedSecret 파일을 별도 적용한다.

## 향후 계획 (Helm 전환 시)

- `instances` → values 파라미터화
- `storage.size` → values 분리
- bootstrap Secret → Sealed Secrets로 대체
- `resources` → values 분리하여 환경별(dev/prod) 조정
