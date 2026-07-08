package io.eds.ignite.kafka;

import org.apache.ignite.Ignite;
import org.apache.ignite.IgniteDataStreamer;
import org.apache.ignite.Ignition;
import org.apache.ignite.stream.StreamSingleTupleExtractor;
import org.apache.ignite.stream.kafka.KafkaStreamer;
import org.apache.kafka.clients.consumer.ConsumerRecord;

import java.util.AbstractMap;
import java.util.Collections;
import java.util.Properties;

/**
 * Kafka → Apache Ignite 실시간 스트리밍 인제스터
 *
 * 아키텍처:
 *   Kafka 토픽(telemetry-events) → KafkaStreamer → IgniteDataStreamer → kafka-hot-cache
 *
 * 클래스명 안내:
 *   Apache Ignite 공식 클래스명은 KafkaStreamer (ignite-kafka 모듈).
 *   ignite-kafka 모듈의 KafkaStreamer 는 내부적으로 IgniteDataStreamer 를 사용하여
 *   고속 배치 인제스트를 수행한다.
 *
 * 실행 방법:
 *   mvn package
 *   java -cp target/kafka-ignite-ingester-1.0.0.jar io.eds.ignite.kafka.KafkaIgniteIngester
 *   또는
 *   java -jar target/kafka-ignite-ingester-1.0.0.jar [ignite-config.xml-경로]
 *
 * 필요 의존성 (pom.xml 참조):
 *   - ignite-core, ignite-kafka, ignite-kubernetes (K8s Discovery용)
 *   - kafka-clients
 */
public class KafkaIgniteIngester {

    // ── 설정 상수 ──────────────────────────────────────────────────────────────
    // ignite-config.xml 의 cache name 과 반드시 일치해야 함
    private static final String CACHE_NAME    = "kafka-hot-cache";

    // 소비할 Kafka 토픽 이름
    private static final String KAFKA_TOPIC   = "telemetry-events";

    // Kafka 브로커 주소 (K8s 내부 DNS 기준)
    // 폐쇄망 환경: 내부 bootstrap 서비스 DNS 또는 IP:포트 사용
    private static final String KAFKA_BROKERS = "kafka-bootstrap.kafka.svc.cluster.local:9092";

    // Kafka Consumer 그룹 ID.
    // 동일 그룹 내 인스턴스가 여러 개면 Kafka 파티션이 자동 분배됨.
    private static final String GROUP_ID      = "ignite-kafka-streamer-group";

    public static void main(String[] args) throws InterruptedException {
        // 인자로 설정 파일 경로 오버라이드 가능 (기본값: classpath의 ignite-config.xml)
        String configPath = args.length > 0 ? args[0] : "ignite-config.xml";

        System.out.println("[KafkaIgniteIngester] Ignite 노드 기동 중... 설정: " + configPath);

        // ── Step 1. Ignite 서버 노드 기동 ──────────────────────────────────────
        // Server 모드: 클러스터에 직접 참여하여 캐시 파티션을 소유.
        // KafkaStreamer → IgniteDataStreamer 는 서버 노드를 통해 직접 적재하므로
        // 네트워크 홉이 없어 Thin Client 모드보다 높은 처리량을 낸다.
        //
        // [서버 모드 vs 클라이언트 모드]
        //   Server Mode  : 파티션 소유, 처리량 최대 → 권장
        //   Client Mode  : 파티션 없음, 경량 연결 → 인제스터를 별도 JVM으로 분리할 때 사용
        //                  Ignition.setClientMode(true); 로 전환
        try (Ignite ignite = Ignition.start(configPath)) {

            System.out.println("[KafkaIgniteIngester] 클러스터 노드 수: "
                    + ignite.cluster().nodes().size());

            // ── Step 2. IgniteDataStreamer 설정 ────────────────────────────────
            // DataStreamer 는 대량 적재를 위한 배치 버퍼링 레이어.
            // 일반 cache.put() 보다 약 10~20배 높은 처리량을 제공한다.
            try (IgniteDataStreamer<String, String> dataStreamer = ignite.dataStreamer(CACHE_NAME)) {

                // 기존 키에 새 값으로 덮어씀.
                // Kafka 재시작 또는 재처리(replay) 시 중복 메시지가 들어와도 최신 값으로 갱신.
                dataStreamer.allowOverwrite(true);

                // 노드당 배치 버퍼 크기 (항목 수).
                // 높을수록 배치가 커져 처리량 증가 / 지연 증가.
                // Kafka 처리량이 높은 환경(>10K msg/s): 4096 이상으로 조정 권장.
                dataStreamer.perNodeBufferSize(2048);

                // 노드당 병렬 적재 스레드 수.
                // 노드 CPU 코어 수의 절반 수준으로 설정.
                dataStreamer.perNodeParallelOperations(4);

                // ── Step 3. KafkaStreamer 설정 ──────────────────────────────────
                // KafkaStreamer 가 내부적으로 Kafka Consumer 스레드를 관리하고
                // 레코드를 IgniteDataStreamer 에 전달한다.
                try (KafkaStreamer<String, String> kafkaStreamer = new KafkaStreamer<>()) {

                    kafkaStreamer.setIgnite(ignite);
                    kafkaStreamer.setStreamer(dataStreamer);

                    // 구독할 Kafka 토픽 목록 (멀티 토픽 지원: Arrays.asList(...) 사용)
                    kafkaStreamer.setTopic(Collections.singletonList(KAFKA_TOPIC));

                    // Kafka Consumer 속성 설정
                    kafkaStreamer.setConsumerConfig(buildKafkaProperties());

                    // 병렬 Consumer 스레드 수.
                    // ⚠️ Kafka 토픽의 파티션 수와 일치시켜야 최대 병렬도 확보.
                    // (예: telemetry-events 가 8 파티션이면 threads=8)
                    kafkaStreamer.setThreads(4);

                    // ── Kafka 레코드 → Ignite 캐시 키-값 매핑 함수 ─────────────
                    // Kafka ConsumerRecord.key()   → Ignite 캐시 Key   (String)
                    // Kafka ConsumerRecord.value() → Ignite 캐시 Value (String / JSON 문자열)
                    //
                    // [JSON 값 파싱이 필요한 경우]
                    // ObjectMapper mapper = new ObjectMapper();
                    // kafkaStreamer.setSingleTupleExtractor(record -> {
                    //     JsonNode json = mapper.readTree(record.value());
                    //     String deviceId = json.get("deviceId").asText();  // JSON 필드를 Key로
                    //     return new AbstractMap.SimpleEntry<>(deviceId, record.value());
                    // });
                    //
                    // [다중 필드를 Ignite Binary Object로 저장하는 경우]
                    // → setSingleTupleExtractor 대신 setMultipleTupleExtractor 사용
                    kafkaStreamer.setSingleTupleExtractor(
                        (StreamSingleTupleExtractor<ConsumerRecord<String, String>, String, String>)
                        record -> new AbstractMap.SimpleEntry<>(record.key(), record.value())
                    );

                    // 스트리밍 시작 (Consumer 스레드 기동)
                    kafkaStreamer.start();

                    System.out.println("[KafkaIgniteIngester] 스트리밍 시작. "
                            + "토픽: [" + KAFKA_TOPIC + "] → 캐시: [" + CACHE_NAME + "] | "
                            + "스레드: " + kafkaStreamer.getThreads());

                    // ── Graceful Shutdown 훅 ────────────────────────────────────
                    // SIGTERM (kubectl delete pod, 롤링 업데이트 등) 또는 Ctrl+C 수신 시
                    // Consumer를 안전하게 닫고 미처리 배치를 플러시한 후 종료한다.
                    Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                        System.out.println("[KafkaIgniteIngester] 종료 신호 수신. 스트리머 정지 중...");
                        kafkaStreamer.stop();   // Consumer 스레드 중단 + 오프셋 커밋
                        // DataStreamer.close() 와 Ignite.close() 는 try-with-resources 로 처리됨
                        System.out.println("[KafkaIgniteIngester] 정상 종료 완료.");
                    }));

                    // 종료 신호가 올 때까지 블락 대기
                    Thread.currentThread().join();
                }
            }
        }
    }

    /**
     * Kafka Consumer 속성 빌더
     *
     * 성능 튜닝 포인트:
     *   - max.poll.records    : poll() 당 최대 레코드 수. 높일수록 배치 효율 증가.
     *   - fetch.min.bytes     : 브로커에서 이 크기 이상 쌓이면 fetch 시작.
     *   - session.timeout.ms  : Ignite GC Pause 동안 Consumer 가 그룹에서 탈퇴하지 않도록
     *                           failureDetectionTimeout 과 같은 30초로 설정.
     */
    private static Properties buildKafkaProperties() {
        Properties props = new Properties();

        // ── 필수 연결 설정 ────────────────────────────────────────────────────
        props.setProperty("bootstrap.servers", KAFKA_BROKERS);
        props.setProperty("group.id",          GROUP_ID);

        // ── 직렬화 설정 ───────────────────────────────────────────────────────
        // Kafka 레코드 Key/Value 를 String 으로 역직렬화
        // JSON value 는 역직렬화 후 매핑 함수에서 ObjectMapper 로 파싱 가능
        props.setProperty("key.deserializer",
                "org.apache.kafka.common.serialization.StringDeserializer");
        props.setProperty("value.deserializer",
                "org.apache.kafka.common.serialization.StringDeserializer");

        // ── 오프셋 정책 ───────────────────────────────────────────────────────
        // earliest: 컨슈머 그룹 최초 기동 시 토픽 처음부터 소비 (재처리 보장)
        // latest  : 이후 들어오는 신규 메시지만 소비
        props.setProperty("auto.offset.reset",  "earliest");

        // KafkaStreamer 가 레코드 처리 후 내부적으로 수동 커밋 수행
        props.setProperty("enable.auto.commit", "false");

        // ── 세션/타임아웃 설정 ────────────────────────────────────────────────
        // Ignite GC Pause 가 길어져도 Consumer 가 그룹에서 탈퇴하지 않도록 여유있게 설정
        // ignite-config.xml 의 failureDetectionTimeout(30s) 과 일치시킴
        props.setProperty("session.timeout.ms",    "30000");
        props.setProperty("heartbeat.interval.ms", "10000");
        // max.poll.interval.ms: records 처리 최대 허용 시간. IgniteDataStreamer flush 포함.
        props.setProperty("max.poll.interval.ms",  "60000");

        // ── 처리량 튜닝 ───────────────────────────────────────────────────────
        // poll() 당 최대 레코드 수. DataStreamer perNodeBufferSize(2048)와 맞추어 설정.
        props.setProperty("max.poll.records",  "500");
        // fetch.min.bytes: 브로커에 최소 64KB 쌓이면 fetch. 배치 효율 향상.
        props.setProperty("fetch.min.bytes",   "65536");
        // fetch.max.wait.ms: fetch.min.bytes 미달 시에도 500ms 후 강제 fetch.
        props.setProperty("fetch.max.wait.ms", "500");
        // receive.buffer.bytes: 대용량 메시지 처리를 위한 소켓 수신 버퍼
        props.setProperty("receive.buffer.bytes", "1048576");  // 1MB

        return props;
    }
}
