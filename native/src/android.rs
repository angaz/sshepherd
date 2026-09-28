use crate::transport::{self, Event};
use jni::{
    objects::{JByteArray, JClass, JString},
    sys::{jboolean, jlong, jstring},
    JNIEnv,
};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicI64, Ordering},
        Mutex, OnceLock,
    },
};
use tokio::{runtime::Runtime, sync::mpsc, task::JoinHandle};

struct Session {
    input: mpsc::Sender<Vec<u8>>,
    events: mpsc::Receiver<Event>,
    task: JoinHandle<()>,
}
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static SESSIONS: OnceLock<Mutex<HashMap<i64, Session>>> = OnceLock::new();
static NEXT: AtomicI64 = AtomicI64::new(1);
fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("Tokio runtime"))
}
fn sessions() -> &'static Mutex<HashMap<i64, Session>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[no_mangle]
pub extern "system" fn Java_io_angaz_sshepherd_Native_open(
    mut env: JNIEnv,
    _: JClass,
    host: JString,
    token: JString,
) -> jlong {
    let Ok(host) = env.get_string(&host).map(String::from) else {
        return 0;
    };
    let Ok(token) = env.get_string(&token).map(String::from) else {
        return 0;
    };
    if !transport::HOSTS.contains(&host.as_str()) || token.is_empty() || token.len() > 8192 {
        return 0;
    }
    let Ok(mut sessions) = sessions().lock() else {
        return 0;
    };
    if !sessions.is_empty() {
        return 0;
    }
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::channel(32);
    let (events, output) = mpsc::channel(32);
    let task = runtime().spawn(transport::run(host, token, rx, events));
    sessions.insert(
        id,
        Session {
            input: tx,
            events: output,
            task,
        },
    );
    id
}

#[no_mangle]
pub extern "system" fn Java_io_angaz_sshepherd_Native_send(
    env: JNIEnv,
    _: JClass,
    id: jlong,
    data: JByteArray,
) -> jboolean {
    if env.get_array_length(&data).map_or(true, |len| len > 65541) {
        return 0;
    }
    let Ok(bytes) = env.convert_byte_array(data) else {
        return 0;
    };
    if bytes.len() > 65541 {
        return 0;
    }
    let Ok(sessions) = sessions().lock() else {
        return 0;
    };
    sessions
        .get(&id)
        .is_some_and(|s| s.input.try_send(bytes).is_ok()) as jboolean
}

#[no_mangle]
pub extern "system" fn Java_io_angaz_sshepherd_Native_poll(
    env: JNIEnv,
    _: JClass,
    id: jlong,
) -> jstring {
    let value = sessions()
        .lock()
        .ok()
        .and_then(|mut sessions| sessions.get_mut(&id).and_then(|s| s.events.try_recv().ok()))
        .and_then(|e| serde_json::to_string(&e).ok())
        .unwrap_or_default();
    env.new_string(value)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "system" fn Java_io_angaz_sshepherd_Native_close(_: JNIEnv, _: JClass, id: jlong) {
    if let Some(session) = sessions()
        .lock()
        .ok()
        .and_then(|mut sessions| sessions.remove(&id))
    {
        drop(session.input);
        // Keep consuming output until EOF has detached the frontend. Dropping
        // the receiver early turns active output into a spurious reconnect.
        runtime().spawn(crate::drain_shutdown(session.task, session.events));
    }
}
