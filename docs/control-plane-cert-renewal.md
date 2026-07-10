# 컨트롤 플레인 인증서 갱신 — 시나리오 및 Q&A 정리

> 관련 스크립트: `scripts/renew-control-plane-certs.sh`

---

## 1. 예상 시나리오

### 정상 시나리오 (Happy Path)

1. **cp-node-1** `check-expiration` → 만료 임박 확인
2. 확인 프롬프트 `y` 입력 → backup → `renew all` → manifests 이동/복귀로 static pod 재시작
3. kubelet이 20초 내 pod 재기동, 이후 최대 180초 폴링 → Ready + control-plane pod Running 확인
4. `check-expiration` 재실행 → 새 만료일(약 1년 후) 출력
5. **cp-node-2, cp-node-3** 순서로 동일 반복
6. 전체 완료. 한 번에 1개 노드만 재시작되므로 나머지 2개가 서빙 — 클러스터는 처음부터 끝까지 API 가용

### 예외 시나리오

| 상황 | 스크립트 동작 | 대응 |
|---|---|---|
| SSH 접속 실패 (VPN 안됨, 키 불일치) | 해당 노드에서 즉시 에러 종료 (`set -euo pipefail`) | SSH_KEY/SSH_USER/터널 상태 확인 후 재실행 |
| manifests 이동 후 kubelet이 20초 내 pod를 못 내림 | 그대로 진행되어 재시작 타이밍이 어긋날 수 있음 | sleep 값(20s)을 늘려서 재시도, 또는 수동으로 `crictl ps`로 확인 |
| pod는 뜨는데 새 인증서가 안 맞음 (예: front-proxy-client 갱신 누락) | apiserver CrashLoop → node/pod Ready 안 됨 → `wait_node_ready` 180초 후 타임아웃, 스크립트 abort | 해당 노드 SSH 접속해 `kubectl logs`/`crictl logs`로 apiserver 원인 확인, 백업본으로 롤백 검토 |
| 첫 노드 처리 중 실패, 두 번째 노드로 그대로 넘어가면 etcd quorum 위험 | 스크립트가 첫 실패 시 즉시 `exit 1` (다음 노드로 안 넘어감) — quorum 손실 방지 | 실패한 노드를 완전히 복구한 뒤에만 다음 노드 진행 |
| `--yes` 없이 프롬프트에서 실수로 `n` | 해당 노드 skip, 다음 노드로 진행 | 의도한 게 아니면 `--node <host>`로 그 노드만 재실행 |
| 인증서 백업 후 renew는 됐는데 재시작 단계에서 세션 끊김(SSH timeout) | manifests가 `/tmp/manifests-backup-*`에 남아있고 원래 위치엔 없을 수 있음 → kubelet이 control-plane pod 자체를 못 찾음 | 해당 노드 재접속해 `/tmp/manifests-backup-*` → `/etc/kubernetes/manifests`로 수동 복귀 필요 |
| 3개 노드 모두 정상 완료했지만 kubelet client cert(별도, kubeadm 관리 외)가 만료 임박 | 이 스크립트 범위 밖 (kubeadm PKI만 다룸) | `/var/lib/kubelet/pki` 별도 확인 필요 (kubelet 자동 rotation 여부 체크) |

가장 위험한 지점은 **재시작 후 Ready 타임아웃 케이스**(apiserver가 새 인증서로 못 뜨는 경우)이므로, 백업 tarball 경로(`/etc/kubernetes/pki-backup-*.tar.gz`)를 노드별로 기억해두면 롤백이 빠름.

---

## 2. Worker 노드는 왜 작업이 필요 없는가

1. **인증서 종류 자체가 다름** — `kubeadm certs renew all`이 다루는 8종 인증서(apiserver, apiserver-kubelet-client, front-proxy-ca/client, etcd ca/server/peer/healthcheck-client)는 전부 컨트롤 플레인 static pod(apiserver, etcd, controller-manager, scheduler)용. Worker 노드엔 이 static pod들이 아예 없으므로 해당 인증서 자체가 존재하지 않음.
2. **Worker의 kubelet 인증서는 자동 갱신됨** — worker에 있는 건 `kubelet.conf`(kubelet이 API server에 접속할 때 쓰는 client cert)뿐인데, kubeadm 클러스터는 기본적으로 kubelet `rotateCertificates: true`가 켜져 있어서 만료 전에 kubelet이 스스로 새 CSR을 발급하고 `kube-controller-manager`의 자동 승인자가 승인 → 사람 개입 없이 교체됨.
3. **kube-proxy 등 애드온은 인증서가 아니라 토큰 기반** — projected service account token을 쓰고 kubelet이 자동으로 갱신해주므로 만료 이슈 자체가 없음.

**확인해볼 것**: 혹시 클러스터가 `rotateCertificates`를 명시적으로 꺼놨다면 얘기가 달라짐 — worker 노드 하나에서 `ps aux | grep kubelet` 또는 `/var/lib/kubelet/config.yaml`에서 `rotateCertificates` 값 확인 권장.

---

## 3. 컨트롤 플레인은 왜 사람 개입이 필요한가

1. **자동 rotation을 수행하는 컨트롤러가 아예 없음** — kubelet의 자동 갱신은 kubelet 프로세스 자체가 "인증서 만료 감시 + CSR 재발급 + 승인 요청"을 하는 상시 에이전트 로직을 갖고 있어서 가능한 것. 반면 apiserver/controller-manager/scheduler/etcd 인증서는 kubeadm이 `init`/`join` 시점에 파일로 한 번 찍어놓고 끝 — 이후 만료를 감시하며 자동으로 갱신해주는 상시 프로세스가 없음. kubeadm은 데몬이 아니라 그때그때 실행하는 CLI 도구.
2. **닭과 달걀 문제** — kubelet의 CSR을 승인해주는 주체가 바로 `kube-controller-manager`(의 CSR approver). 그런데 컨트롤 플레인 인증서 자체를 auto-rotation 시키려면 그 rotation을 승인/처리할 주체가 필요한데, 그게 바로 갱신 대상인 컴포넌트 자신들임. 특히 etcd는 K8s CSR API 자체를 모르는 완전히 별개 시스템이라 이 메커니즘에 낄 수도 없음.
3. **갱신 = 컴포넌트 재시작이 필수, 그리고 그게 위험함** — kubelet 인증서는 살아있는 프로세스가 무중단으로 교체 가능(serving cert hot-swap 구조). 반면 apiserver/etcd 등은 인증서를 새로 반영하려면 static pod 자체를 죽였다 살려야 함. etcd는 quorum 멤버라서 잘못 자동화하면 여러 노드가 동시에 재시작되며 quorum 손실 위험이 있음 — 그래서 kubeadm이 자동 재시작을 시키지 않고, 사람이 타이밍/순서를 통제하도록 명시적 작업(`kubeadm certs renew` + 수동 재시작)으로 남겨둠.
4. **유일한 예외**: `kubeadm upgrade apply`/`kubeadm upgrade node`를 실행하면 그 부수효과로 인증서가 자동 갱신됨 (아래 4번 참고).

---

## 4. `kubeadm upgrade` 시 자동 갱신되는 방식

1. **첫 컨트롤 플레인 노드**에서 `kubeadm upgrade apply <version>` 실행 시:
   - 새 이미지 pull, preflight 체크
   - 기존 static pod manifest + `/etc/kubernetes/pki`를 `/etc/kubernetes/tmp`에 백업
   - **내부적으로 `kubeadm certs renew all`과 동일한 로직을 자동 호출** → apiserver, apiserver-kubelet-client, front-proxy-client, etcd server/peer/healthcheck-client, apiserver-etcd-client 등 leaf 인증서를 기존 CA로 전부 재발급 (남은 유효기간과 무관하게 매번 무조건 갱신됨)
   - 버전 변경을 위해 어차피 새 static pod manifest를 `/etc/kubernetes/manifests`에 새로 씀 → kubelet이 변경을 감지하고 pod를 알아서 재시작
   - **"버전 업그레이드로 인한 재시작"과 "새 인증서 적용"이 같은 재시작 한 번에 묶여서 일어남** — 별도로 재시작을 트리거할 필요가 없어짐

2. **나머지 컨트롤 플레인 노드들**은 각각 SSH로 들어가 `kubeadm upgrade node` 실행 → 동일하게 그 노드의 인증서 재발급 + manifest 갱신 + 로컬 static pod 재시작. **노드별로 한 번에 하나씩** 실행 — `renew-control-plane-certs.sh`의 순차 처리 패턴과 동일한 이유(etcd quorum 보호).

3. `--certificate-renewal=false` 옵션으로 이 자동 갱신을 끌 수 있음 (기본값은 활성화).

4. **CA 인증서(ca.crt/key, front-proxy-ca, etcd/ca) 자체는 포함 안 됨** — leaf 인증서만 갱신되고, CA는 기본 10년 유효기간이라 별도 절차 없이는 손대지 않음. CA 교체는 완전히 별개의(훨씬 위험한) 작업.

**요약**: 업그레이드는 어차피 이미지 버전 교체 때문에 pod를 재시작해야 하니, 그 김에 인증서도 같이 갈아끼우는 구조. 업그레이드를 안 하면 그 재시작 트리거 자체가 없어서 사람이 직접 만들어줘야 함 (`kubeadm certs renew` + 수동 재시작).
