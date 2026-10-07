use super::*;

struct Peer {
    send: quinn::SendStream,
    recv: quinn::RecvStream,
    decoder: proto::FrameDecoder,
    conn: quinn::Connection,
}
impl Peer {
    async fn accept(server: &quinn::Endpoint) -> Self {
        let conn = server.accept().await.unwrap().await.unwrap();
        let (send, recv) = conn.accept_bi().await.unwrap();
        Self {
            send,
            recv,
            conn,
            decoder: proto::FrameDecoder::new(),
        }
    }
    async fn recv<T: serde::de::DeserializeOwned>(&mut self) -> T {
        loop {
            if let Some(frame) = self.decoder.next_frame().unwrap() {
                return proto::decode(&frame).unwrap();
            }
            let chunk = self.recv.read_chunk(65536, true).await.unwrap().unwrap();
            self.decoder.push(&chunk.bytes);
        }
    }
    async fn send<T: Serialize>(&mut self, message: &T) {
        let bytes = proto::encode_frame(message).unwrap();
        // Force the client to reassemble both length prefix and body.
        for chunk in bytes.chunks(3) {
            self.send.write_all(chunk).await.unwrap();
            tokio::task::yield_now().await;
        }
    }
    async fn hello(&mut self) {
        let hello: proto::Hello = self.recv().await;
        assert_eq!(hello.token, "fixture-token");
        self.send(&proto::Welcome {
            user: "test".into(),
            server_version: "fixture".into(),
        })
        .await;
    }
}
fn server() -> quinn::Endpoint {
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(cert.key_pair.serialize_der());
    let mut tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert.cert.der().clone()], key.into())
    .unwrap();
    tls.alpn_protocols = vec![proto::PROTOCOL.as_bytes().to_vec()];
    let config = quinn::ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(tls).unwrap(),
    ));
    quinn::Endpoint::server(config, "127.0.0.1:0".parse().unwrap()).unwrap()
}

fn vt_frame(data: &[u8]) -> Vec<u8> {
    let mut wire = vec![1];
    wire.extend_from_slice(&(data.len() as u32).to_be_bytes());
    wire.extend_from_slice(data); wire
}

#[tokio::test]
async fn real_quic_resume_deduplicates_output_and_replays_unacked_input() {
    tokio::time::timeout(Duration::from_secs(15), async {
        let server = server();
        let addr = server.local_addr().unwrap();
        let fixture = tokio::spawn(async move {
            let mut peer = Peer::accept(&server).await;
            peer.hello().await;
            let request: proto::ExecRequest = peer.recv().await;
            assert!(matches!(request, proto::ExecRequest::Exec { resumable: true, forward_agent: false, .. }));
            peer.send(&Msg::Started { resume_token: Some("resume-token".into()) }).await;
            let stdin: Msg = peer.recv().await;
            let Msg::Stdin { seq: 1, data } = stdin else { panic!("expected first stdin"); };
            assert_eq!(data, b"fixture-input");
            // Withhold stdin ACK and interrupt mid bridge frame. Its decoder
            // must preserve partial bytes while Eternal deduplicates replay.
            peer.send(&Msg::Stdout { seq: 1, data: vt_frame(b"first")[..7].to_vec() }).await;
            let ack: Msg = peer.recv().await;
            assert!(matches!(ack, Msg::Ack { seq: 1 }));
            peer.conn.close(0u32.into(), b"simulated roaming");
            let mut peer = Peer::accept(&server).await;
            peer.hello().await;
            let request: proto::ExecRequest = peer.recv().await;
            assert!(matches!(request, proto::ExecRequest::Resume { ref resume_token, last_seq_seen: 1 } if resume_token == "resume-token"));
            peer.send(&Msg::Started { resume_token: Some("resume-token".into()) }).await;
            let resent: Msg = peer.recv().await;
            assert!(matches!(resent, Msg::Stdin { seq: 1, ref data } if data == b"fixture-input"));
            peer.send(&Msg::Ack { seq: 1 }).await;
            peer.send(&Msg::Stdout { seq: 1, data: vt_frame(b"first")[..7].to_vec() }).await;
            peer.send(&Msg::Stdout { seq: 2, data: [vt_frame(b"first")[7..].to_vec(), vt_frame(b"second")].concat() }).await;
            for _ in 0..2 { let _: Msg = peer.recv().await; }
            peer.send(&Msg::Exit { seq: 3, code: 0 }).await;
            let ack: Msg = peer.recv().await;
            assert!(matches!(ack, Msg::Ack { seq: 3 }));
        });
        let (input, rx) = mpsc::channel(4);
        let (events, mut output) = mpsc::channel(32);
        input.send(b"fixture-input".to_vec()).await.unwrap();
        session(addr, "localhost", "fixture-token", rx, &events).await.unwrap();
        fixture.await.unwrap();
        drop(events);
        let mut bytes = Vec::new();
        let mut phases = Vec::new();
        while let Some(event) = output.recv().await {
            match event {
                Event::Output { data } => bytes.extend(STANDARD.decode(data).unwrap()),
                Event::Status { phase, .. } => phases.push(phase),
                Event::Directory { .. } => panic!("unexpected directory response"),
            }
        }
        assert_eq!(bytes, b"firstsecond");
        assert!(phases.contains(&"reconnecting"));
        assert_eq!(phases.last(), Some(&"closed"));
    }).await.unwrap();
}

#[tokio::test]
async fn denied_resume_is_terminal_not_a_new_exec() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let server = server();
        let addr = server.local_addr().unwrap();
        let fixture = tokio::spawn(async move {
            let mut peer = Peer::accept(&server).await;
            peer.hello().await;
            let request: proto::ExecRequest = peer.recv().await;
            assert!(matches!(request, proto::ExecRequest::Exec { .. }));
            peer.send(&Msg::Started {
                resume_token: Some("resume-token".into()),
            })
            .await;
            peer.send(&Msg::Stdout {
                seq: 1,
                data: vt_frame(b"ready"),
            })
            .await;
            let _: Msg = peer.recv().await;
            peer.conn.close(0u32.into(), b"roaming");
            let mut peer = Peer::accept(&server).await;
            peer.hello().await;
            let request: proto::ExecRequest = peer.recv().await;
            assert!(matches!(request, proto::ExecRequest::Resume { .. }));
            peer.send(&Msg::Denied {
                reason: "fixture denied".into(),
            })
            .await;
            // Keep the connection alive until the peer consumes the denial.
            peer.conn.closed().await;
        });
        let (_input, rx) = mpsc::channel(4);
        let (events, _output) = mpsc::channel(32);
        let error = session(addr, "localhost", "fixture-token", rx, &events)
            .await
            .unwrap_err();
        assert!(error.to_string().contains("fixture denied"));
        fixture.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn explicit_close_drains_active_output_and_sends_eof_without_resume() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let server = server();
        let addr = server.local_addr().unwrap();
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let fixture = tokio::spawn(async move {
            let mut peer = Peer::accept(&server).await;
            peer.hello().await;
            let _: proto::ExecRequest = peer.recv().await;
            peer.send(&Msg::Started {
                resume_token: Some("resume-token".into()),
            })
            .await;
            peer.send(&Msg::Stdout {
                seq: 1,
                data: vt_frame(&vec![b'x'; 1024]),
            })
            .await;
            let _ = ready_tx.send(());
            loop {
                match peer.recv::<Msg>().await {
                    Msg::StdinEof { .. } => break,
                    Msg::Ack { .. } => {}
                    other => panic!("unexpected: {other:?}"),
                }
            }
            // Keep endpoint alive while EOF is transport-ACKed; no new session
            // may be opened in response to explicit detach.
            assert!(tokio::time::timeout(Duration::from_millis(500), server.accept()).await.is_err());
        });
        let (input, rx) = mpsc::channel(4);
        // Capacity one guarantees output may be blocked behind status.
        let (events, output) = mpsc::channel(1);
        let task = tokio::spawn(async move {
            session(addr, "localhost", "fixture-token", rx, &events)
                .await
                .unwrap();
        });
        ready_rx.await.unwrap();
        drop(input);
        crate::drain_shutdown(task, output).await;
        fixture.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn malformed_host_is_rejected_before_dns_or_network() {
    let (_input, rx) = mpsc::channel(1);
    let (events, mut output) = mpsc::channel(4);
    run(
        "https://attacker.example".into(),
        "fixture-token".into(),
        rx,
        events,
    )
    .await;
    assert!(matches!(
        output.recv().await,
        Some(Event::Status { phase: "error", .. })
    ));
}
