use std::{collections::VecDeque, net::SocketAddr, sync::Arc, time::Duration};

use anyhow::{anyhow, bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use herdr_eternal_proto::{self as proto, ChannelMessage as Msg};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
    DigitallySignedStruct, SignatureScheme,
};
use serde::Serialize;
use tokio::sync::mpsc;

pub const HOSTS: &[&str] = &["host-a", "host-b", "host-c", "host-d", "host-e", "host-f"];
const REPLAY_LIMIT: usize = 256 * 1024;

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Event {
    Status {
        phase: &'static str,
        message: String,
    },
    Output {
        data: String,
    },
}

async fn status(events: &mpsc::Sender<Event>, phase: &'static str, message: impl Into<String>) {
    let _ = events
        .send(Event::Status {
            phase,
            message: message.into(),
        })
        .await;
}

// Certificate verification is disabled only with explicit user consent.
// for the fixed network inventory, after explicit consent in the Android UI.
// Authenticate server identity independently; the self-signed TLS cert does not.
#[derive(Debug)]
struct ConsentedServerIdentity;
impl ServerCertVerifier for ConsentedServerIdentity {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        msg: &[u8],
        cert: &CertificateDer<'_>,
        sig: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            msg,
            cert,
            sig,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        msg: &[u8],
        cert: &CertificateDer<'_>,
        sig: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            msg,
            cert,
            sig,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

struct Connection {
    send: quinn::SendStream,
    recv: quinn::RecvStream,
    decoder: proto::FrameDecoder,
    connection: quinn::Connection,
    _endpoint: quinn::Endpoint,
}
impl Drop for Connection {
    fn drop(&mut self) {
        self.connection.close(0u32.into(), b"detached");
    }
}
impl Connection {
    async fn open(addr: SocketAddr, host: &str) -> Result<Self> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut tls = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(ConsentedServerIdentity))
            .with_no_client_auth();
        tls.alpn_protocols = vec![proto::PROTOCOL.as_bytes().to_vec()];
        let mut config = quinn::ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(tls)?,
        ));
        let mut transport = quinn::TransportConfig::default();
        transport.keep_alive_interval(Some(Duration::from_secs(5)));
        transport.max_idle_timeout(Some(Duration::from_secs(15).try_into()?));
        config.transport_config(Arc::new(transport));
        let mut endpoint = quinn::Endpoint::client(if addr.is_ipv6() {
            "[::]:0".parse()?
        } else {
            "0.0.0.0:0".parse()?
        })?;
        endpoint.set_default_client_config(config);
        let connection = endpoint.connect(addr, host)?.await?;
        let (send, recv) = connection.open_bi().await?;
        Ok(Self {
            send,
            recv,
            decoder: proto::FrameDecoder::new(),
            connection,
            _endpoint: endpoint,
        })
    }
    async fn send<T: Serialize>(&mut self, value: &T) -> Result<()> {
        self.send.write_all(&proto::encode_frame(value)?).await?;
        Ok(())
    }
    // The decoder is owned by the connection, not this future: select!
    // cancellation between packets never loses a partial frame.
    async fn receive<T: serde::de::DeserializeOwned>(&mut self) -> Result<T> {
        loop {
            if let Some(frame) = self.decoder.next_frame()? {
                return Ok(proto::decode(&frame)?);
            }
            let chunk = self
                .recv
                .read_chunk(65536, true)
                .await?
                .context("Server disconnected")?;
            self.decoder.push(&chunk.bytes);
        }
    }
}

fn command() -> String {
    let encoded = STANDARD.encode(include_bytes!("../pty_bridge.py"));
    // Only compiled-in source is embedded, never a hostname, token or user input.
    format!("python3 -u -c \"import base64;exec(compile(base64.b64decode('{encoded}'),'sshepherd-pty','exec'))\"")
}

pub async fn run(
    host: String,
    token: String,
    input: mpsc::Receiver<Vec<u8>>,
    events: mpsc::Sender<Event>,
) {
    let result = async {
        if !HOSTS.contains(&host.as_str()) { bail!("Unknown server"); }
        if token.trim().is_empty() || token.len() > 8192 { bail!("Set a valid token in Settings"); }
        let name = format!("{host}.example.invalid");
        status(&events, "connecting", "Resolving server address…").await;
        // These servers listen on ULA IPv6 only. Do not leak the bearer token
        // to a public address due to a mistaken DNS resolver/search domain.
        let addr = tokio::time::timeout(Duration::from_secs(8), tokio::net::lookup_host((name.as_str(), 7443)))
            .await.context("DNS timed out; check connectivity")??
            .find(|addr| matches!(addr.ip(), std::net::IpAddr::V6(ip) if (ip.segments()[0] & 0xfe00) == 0xfc00))
            .context("No allowed ULA IPv6 address; check VPN and mesh DNS")?;
        session(addr, &name, &token, input, &events).await
    }.await;
    if let Err(error) = result {
        status(&events, "error", format!("{error:#}")).await;
    }
}

async fn session(
    addr: SocketAddr,
    name: &str,
    token: &str,
    mut input: mpsc::Receiver<Vec<u8>>,
    events: &mpsc::Sender<Event>,
) -> Result<()> {
    let mut resume: Option<String> = None;
    let mut seen = 0u64;
    let mut sequence = 0u64;
    let mut replay: VecDeque<(u64, Vec<u8>)> = VecDeque::new();
    let mut replay_bytes = 0usize;
    let mut retry_since: Option<tokio::time::Instant> = None;
    loop {
        let handshake = async {
            let mut conn = Connection::open(addr, name).await?;
            conn.send(&proto::Hello {
                token: token.into(),
                client_name: "sshepherd".into(),
                client_version: env!("CARGO_PKG_VERSION").into(),
            })
            .await?;
            let _: proto::Welcome = conn.receive().await?;
            let request = match &resume {
                Some(token) => proto::ExecRequest::Resume {
                    resume_token: token.clone(),
                    last_seq_seen: seen,
                },
                None => proto::ExecRequest::Exec {
                    command: command(),
                    resumable: true,
                    forward_agent: false,
                },
            };
            conn.send(&request).await?;
            let reply: Msg = conn.receive().await?;
            Ok::<_, anyhow::Error>((conn, reply))
        };
        let attempt = tokio::time::timeout(Duration::from_secs(8), handshake).await;
        let mut conn = match attempt {
            Ok(Ok((conn, Msg::Started { resume_token }))) => {
                if resume.is_none() {
                    resume = resume_token;
                }
                conn
            }
            Ok(Ok((_, Msg::Denied { reason }))) => bail!("Session rejected: {reason}"),
            Ok(Ok(_)) => bail!("Unexpected Eternal handshake response"),
            other => {
                if resume.is_none() {
                    return Err(anyhow!("QUIC connection/authentication failed; check connectivity, token and UDP 7443: {}", match other { Ok(Err(e)) => e.to_string(), _ => "timeout".into() }));
                }
                let since = retry_since.get_or_insert_with(tokio::time::Instant::now);
                if since.elapsed() > Duration::from_secs(90) {
                    bail!("Reconnect timed out. Return to servers and reconnect.");
                }
                status(
                    events,
                    "reconnecting",
                    "Reconnecting; resuming the same session…",
                )
                .await;
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            }
        };
        status(events, "connected", "Connected").await;
        let attached: Result<()> = async {
            for (seq, data) in &replay { conn.send(&Msg::Stdin { seq: *seq, data: data.clone() }).await?; }
            retry_since = None;
            loop {
                tokio::select! {
                    data = input.recv(), if replay_bytes < REPLAY_LIMIT => {
                        let Some(data) = data else {
                            sequence += 1;
                            // EOF terminates only our PTY frontend, never the persistent Herdr server.
                            let _ = conn.send(&Msg::StdinEof { seq: sequence }).await;
                            return Ok(());
                        };
                        if data.len() > 65541 { bail!("Input frame exceeds limit"); }
                        sequence += 1;
                        replay_bytes += data.len();
                        replay.push_back((sequence, data.clone()));
                        conn.send(&Msg::Stdin { seq: sequence, data }).await?;
                    }
                    message = conn.receive::<Msg>() => {
                        match message? {
                            Msg::Stdout { seq, data } | Msg::Stderr { seq, data } => {
                                if seq > seen {
                                    events.send(Event::Output { data: STANDARD.encode(&data) }).await.context("View closed")?;
                                    seen = seq;
                                }
                                conn.send(&Msg::Ack { seq: seen }).await?;
                            }
                            Msg::Ack { seq } => {
                                while replay.front().is_some_and(|(s, _)| *s <= seq) {
                                    replay_bytes -= replay.pop_front().unwrap().1.len();
                                }
                            }
                            Msg::Exit { seq, code } => {
                                let _ = conn.send(&Msg::Ack { seq }).await;
                                status(events, "closed", format!("Herdr client exited ({code}). Remote panes are unchanged.")).await;
                                return Ok(());
                            }
                            Msg::Denied { reason } => {
                                status(events, "error", reason).await;
                                return Ok(());
                            }
                            _ => {}
                        }
                    }
                }
            }
        }.await;
        if attached.is_ok() {
            let _ = conn.send.finish();
            // write_all queues data; closing QUIC immediately would discard the
            // final ACK/EOF before it reaches Eternal.
            let _ = tokio::time::timeout(Duration::from_secs(1), conn.send.stopped()).await;
            return Ok(());
        }
        if resume.is_none() {
            return attached;
        }
        status(
            events,
            "reconnecting",
            "Connection interrupted; input paused…",
        )
        .await;
        retry_since.get_or_insert_with(tokio::time::Instant::now);
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

#[cfg(test)]
#[path = "transport_tests.rs"]
mod integration_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn remote_command_contains_only_bundled_source() {
        let command = command();
        assert!(command.starts_with("python3 -u -c"));
        assert!(!command.contains("token"));
        assert!(!command.contains("mesh.example.invalid"));
    }
    #[test]
    fn inventory_matches_nix() {
        assert_eq!(HOSTS.len(), 6);
        assert!(HOSTS.contains(&"host-a"));
    }
}
