# Ignite / Redis / PostgreSQL 재기동 후 데이터 휘발 테스트

> 목적: Ignite, Redis, PostgreSQL에 동일한 `death` 테이블(26행, `sample/7.DEATH.csv` 기반)을
> 각각 만들어두고, 세 서비스를 모두 강제 재기동한 뒤 데이터가 남아있는지 확인.

---

## 1. 테스트 절차 (실행 순서 그대로)

1. **사전 상태 확인**: 세 카탈로그(`ignite.public.death`, `postgresql.public.death`,
   `redis.default.death`) 모두 26행으로 일치하는 것을 Trino로 확인.
2. **재기동 전 스냅샷**: `kubectl get pods -o wide`로 `ignite-cluster-0`, `redis-0`,
   `eds-pg-1` 각각의 현재 Pod 확인.
3. **강제 재기동**: 세 Pod를 동시에 `kubectl delete pod`로 삭제
   (StatefulSet/CNPG Cluster가 자동으로 재생성).
   ```
   kubectl delete pod ignite-cluster-0 -n ignite
   kubectl delete pod redis-0 -n redis
   kubectl delete pod eds-pg-1 -n cnpg
   ```
4. **Ready 대기**: `kubectl wait --for=condition=Ready` — Redis와 PostgreSQL은 정상적으로
   Ready 상태 도달. **Ignite만 `CrashLoopBackOff`** 발생.
5. **Ignite 크래시 원인 분석** (재기동 테스트 도중 발견된 별개 이슈):
   - 로그: `ClassNotFoundException: TcpDiscoveryKubernetesIpFinder`
   - 원인: 이전에 NodePort 노출 작업을 하며 `kubectl apply -f ignite.yaml`을 실행했을 때,
     실제 운영 중이던 ConfigMap(`ignite-config`)이 리포지토리 버전으로 덮어써졌음.
     StatefulSet은 `serviceName` 불변 필드 충돌로 업데이트가 막혀 있었기 때문에,
     기존 JVM 프로세스는 2일간 그대로 떠 있었고 **이번 재기동이 처음으로 새 설정을
     실제로 읽어들인 시점**이었음. 새 설정은 `ignite-kubernetes` 모듈(K8s API 기반 노드 탐색)이
     필요한데 해당 모듈을 클래스패스에 올리는 `OPTION_LIBS` 환경변수가 실제 StatefulSet에는
     없었음 → 클래스 로드 실패.
   - 조치: `discoverySpi.ipFinder`를 `TcpDiscoveryKubernetesIpFinder` →
     `TcpDiscoveryVmIpFinder`(정적 주소 `ignite-svc-headless:47500..47509`)로 되돌림.
     단일 replica 구성이라 K8s API 기반 동적 탐색이 애초에 불필요했던 설정.
   - 추가로 발견된 버그: `StopNodeOrHaltFailureHandler`의 `tryStop` 프로퍼티는
     Ignite 2.18.0에서 생성자 인자로만 설정 가능(setter 없음) → Spring XML
     `<property>` 주입 시 `NotWritablePropertyException`. 기본 생성자로 수정.
   - 두 수정 모두 실제 운영 이미지(`apacheignite/ignite:2.18.0`)를 대상으로 클래스 파일까지
     직접 열어 확인 후 반영.
6. **Ignite 재기동 재시도**: 수정된 설정 적용 후 `ignite-cluster-0` 정상 기동
   (`Topology snapshot [ver=1, servers=1, ... state=ACTIVE]`).
7. **재기동 후 데이터 확인** (Trino로 3개 카탈로그 동시 조회):

   | 카탈로그 | 재기동 전 | 재기동 후 |
   |---|---|---|
   | `ignite.public.death` | 26행 | **테이블 자체가 사라짐** (`Table does not exist`) |
   | `postgresql.public.death` | 26행 | 26행 (그대로) |
   | `redis.default.death` | 26행 | 26행 (그대로) |

---

## 2. 왜 Redis는 남고 Ignite는 사라졌나

둘 다 "인메모리 DB"로 분류되지만, **인메모리는 "서빙 방식"이지 "영속성 여부"와는 별개**입니다.
이 배포에서 실제로 다른 건 각 서비스의 영속성(persistence) 설정입니다.

| 항목 | Redis | Ignite (이 배포) | PostgreSQL |
|---|---|---|---|
| 데이터 서빙 위치 | 메모리 | 메모리(Off-heap) | 메모리(캐시) + 디스크 |
| 디스크 영속화 | **AOF 활성화** (`appendonly yes`, `appendfsync everysec`) + RDB 스냅샷(`dump.rdb`) | **비활성화** (`persistenceEnabled=false`, `walMode=NONE`) | WAL 기반 영구 저장 (기본 RDBMS) |
| 재기동 시 복구 방법 | 시작 시 AOF/RDB 파일을 디스크에서 읽어 메모리 재구성 | 복구할 디스크 데이터 자체가 없음 → 빈 상태로 시작 | WAL replay + 데이터 파일에서 그대로 로드 |
| PVC 마운트 | `/data` (`csi-cinder-sc-retain`, 5Gi) | `/opt/ignite/work` (PVC는 있지만 persistence 꺼져 있어 실제 캐시 데이터는 안 쓰임) | `/var/lib/postgresql/data` 등 (CNPG 관리, 10Gi) |

즉 Ignite도 persistence를 켰다면(`persistenceEnabled=true`, WAL 활성화) 재기동 후에도 데이터가
남았을 것입니다. 이 배포에서 껐던 이유는 `ignite-config.xml` 주석에 나와 있듯
"Kafka Hot Buffer" 용도로 설계되었기 때문 — Kafka/Spark/Trino가 원본 소스이고 Ignite는
빠른 조회를 위한 휘발성 캐시 계층으로 의도된 것 (재구성 가능한 데이터만 올리는 용도).
**즉 이번 결과는 버그가 아니라 설계대로 동작한 것**이며, 이 구조를 쓸 때는 "Ignite에만 있고
원본에 없는 데이터는 재기동 시 사라진다"는 전제를 반드시 인지하고 있어야 합니다.

---

## 3. 인메모리 DB에서 데이터가 날아갈 수 있는 일반적인 케이스

### Redis (현재 설정 기준으로도 해당될 수 있는 것들)

| 케이스 | 설명 |
|---|---|
| Persistence 자체를 껐을 때 | `appendonly no` + RDB `save` 포인트도 없으면, 지금 Ignite처럼 재기동만으로도 전부 소실 |
| **비정상 종료(kill -9, OOM kill, 노드 장애)** | `appendfsync everysec`이라 최대 1초 분량의 최근 쓰기는 아직 디스크에 fsync되지 않았을 수 있음 → 그 구간 데이터만 유실 가능 (완전 소실은 아니지만 최근 데이터 일부 유실) |
| **maxmemory + eviction 정책** | 이 배포는 `maxmemory 512mb`, `maxmemory-policy allkeys-lru`로 설정되어 있음 → 메모리 한도 초과 시 **재기동 없이도** 오래 안 쓰인 키가 자동으로 삭제됨. 재기동과 무관한 소실 경로 |
| PVC/PV 삭제 또는 유실 | StorageClass의 `reclaimPolicy=Delete`인 볼륨은 PVC 삭제 시 실제 데이터도 같이 삭제됨 (이 배포는 `csi-cinder-sc-retain`이라 PVC를 지워도 볼륨은 남지만, 네임스페이스째 삭제하는 등 실수 시 여전히 위험) |
| AOF 파일 자체 손상 | 비정상 종료 후 AOF 파일이 중간에 잘린 상태(truncated)면 시작 시 로드 실패 가능 (Redis가 자동 복구를 시도하지만 항상 성공하는 건 아님) |

### Ignite (persistence를 켠다고 가정해도 남는 리스크)

| 케이스 | 설명 |
|---|---|
| Persistence 비활성화 (현재 상태) | 재기동/크래시/OOM 등 어떤 이유로든 프로세스가 재시작되면 100% 소실 |
| WAL 비활성화(`walMode=NONE`) | persistence를 켜더라도 WAL이 없으면 마지막 체크포인트 이후 변경분은 비정상 종료 시 유실 |
| 체크포인트 주기 사이 장애 | WAL이 있어도 체크포인트 간격이 길면 그 사이 발생한 쓰기는 복구 시 재생(replay)에 의존 — WAL 손상 시 유실 |
| PVC 삭제/유실 | persistence를 켜서 디스크에 쓰더라도, 그 볼륨 자체가 삭제되면 당연히 소실 |
| 단일 노드 + 파티션 손실 정책 | `partitionLossPolicy` 설정에 따라 일부 파티션 유실 시 전체 캐시를 못 쓰게 되거나 데이터 일부만 사라질 수 있음 |

### PostgreSQL / 공통 리스크

| 케이스 | 설명 |
|---|---|
| `fsync=off` 또는 `synchronous_commit=off` 같은 튜닝 | 성능을 위해 내구성을 낮추면 크래시 시 최근 커밋 유실 가능 (이 배포는 기본값이라 해당 없음) |
| PVC 삭제/노드 디스크 장애 | WAL 기반이라도 볼륨 자체가 사라지면 동일하게 소실 |
| **StatefulSet/Cluster CR 삭제 시 PVC 자동 삭제 정책** | `persistentVolumeClaimRetentionPolicy`(StatefulSet) 또는 CNPG의 볼륨 정책에 따라 리소스 삭제와 함께 PVC까지 연쇄 삭제될 수 있음 — Pod 재기동과는 다른, "리소스 자체를 지우는" 경로이니 별도 주의 필요 |

---

## 4. 결론

- 이번 테스트에서 **PostgreSQL과 Redis는 재기동에도 데이터가 남았고, Ignite만 사라졌음** —
  이는 버그가 아니라 Ignite가 persistence 없이 순수 인메모리 핫 버퍼로 설계되었기 때문.
- "인메모리 DB"라는 이름만으로 내구성을 판단하면 안 되고, **persistence 설정(AOF/RDB, WAL,
  PVC 백업 여부)이 실제 복구 가능 여부를 결정**한다는 것이 핵심.
- Ignite를 신뢰 가능한 저장소로 쓰려면 `persistenceEnabled=true` + WAL 활성화가 필요하며,
  그렇지 않다면 "재구성 가능한 데이터만 올린다"는 원칙을 지켜야 함 (현재 아키텍처 의도와 일치).
