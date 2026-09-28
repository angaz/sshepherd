pub mod transport;

/// Drain the bounded UI queue during explicit detach, so output cannot cause
/// a reconnect before the closed input channel is observed and EOF is sent.
pub async fn drain_shutdown(
    mut task: tokio::task::JoinHandle<()>,
    mut events: tokio::sync::mpsc::Receiver<transport::Event>,
) {
    let finish = async {
        loop {
            tokio::select! {
                _ = &mut task => break,
                event = events.recv() => if event.is_none() { let _ = (&mut task).await; break; },
            }
        }
    };
    if tokio::time::timeout(std::time::Duration::from_secs(2), finish)
        .await
        .is_err()
    {
        task.abort();
        let _ = task.await;
    }
}

#[cfg(target_os = "android")]
mod android;
