//! The link adapter: sockets for a `Node` from `imp-core`. The core decides everything (the handshake, who may
//! talk, the book). This file only moves bytes: it listens, dials a device's addresses and its Hop, waits at
//! the Hop for guests and writes what the node asks to be written. The Bonjour lookup the apps do is not here,
//! so a guest finds this device by the host names in its code or through the Hop.

use crate::{CliError, Result};
use imp_core::link::LinkCard;
use imp_core::link::hop::{HopAddress, HopClient, HopCredentials, HopStatus};
use imp_core::link::node::{ConnId, DialRequest, Event, Node, Output, Time};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use uuid::Uuid;

/// How long a dial to one address may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a guest waits for the Hop to splice it in.
const GUEST_WAIT: Duration = Duration::from_secs(20);
/// A little longer than the Hop's own wait for a host, so the Hop is the one that gives up.
const HOST_WAIT: Duration = Duration::from_secs(6 * 60);
const RETRY_FIRST: Duration = Duration::from_secs(2);
const RETRY_LONGEST: Duration = Duration::from_secs(60);

const BOOK_FILE: &str = "link-book";

/// The current time in seconds since 1970, which is what the node's book keeps.
pub fn now() -> Time {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// Where the device's secret seed is kept. The real one is the platform's key store.
pub trait SeedStore: Send + Sync {
    /// The saved seed, or None the first time. The error is a plain sentence for the user.
    fn get(&self) -> std::result::Result<Option<String>, String>;
    fn set(&self, seed: &str) -> std::result::Result<(), String>;
}

const SEED_SERVICE: &str = "imp";
const SEED_ACCOUNT: &str = "link-identity";

/// The key store of the system: the Keychain, the Credential Manager or the Secret Service.
pub struct SystemSeedStore;

impl SystemSeedStore {
    fn entry() -> std::result::Result<keyring::Entry, String> {
        keyring::Entry::new(SEED_SERVICE, SEED_ACCOUNT).map_err(|_| no_key_store())
    }
}

fn no_key_store() -> String {
    "Imp keeps this device's secret in the system key store, and none is available. On Linux, start a Secret Service such as GNOME Keyring or KWallet (it needs a logged-in desktop session), then run the command again.".into()
}

impl SeedStore for SystemSeedStore {
    fn get(&self) -> std::result::Result<Option<String>, String> {
        match Self::entry()?.get_password() {
            Ok(seed) => Ok(Some(seed)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err(no_key_store()),
        }
    }

    fn set(&self, seed: &str) -> std::result::Result<(), String> {
        Self::entry()?
            .set_password(seed)
            .map_err(|_| no_key_store())
    }
}

/// Where the node's book is kept: a file in the data folder that only the owner can read, without the
/// device's secret seed. The seed lives in the key store and is joined to the book when it is read. It is
/// never printed and never written to a file. With no key store the book cannot be used at all.
pub struct BookFile {
    path: PathBuf,
    seeds: Arc<dyn SeedStore>,
}

impl BookFile {
    pub fn in_dir(dir: &Path, seeds: Arc<dyn SeedStore>) -> Self {
        Self {
            path: dir.join(BOOK_FILE),
            seeds,
        }
    }

    /// The saved book with its seed put back, or None the first time.
    pub fn load(&self) -> Result<Option<Vec<u8>>> {
        let seed = self.seeds.get().map_err(CliError)?;
        let bytes = match std::fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => {
                return Err(CliError(format!(
                    "Could not read {}: {e}",
                    self.path.display()
                )));
            }
        };
        let damaged = || {
            CliError(format!(
                "The link book in {} cannot be used. Remove the file to start again.",
                self.path.display()
            ))
        };
        let mut book: serde_json::Map<String, serde_json::Value> =
            serde_json::from_slice(&bytes).map_err(|_| damaged())?;
        if book.contains_key("seed") {
            return Err(damaged());
        }
        let seed = seed.ok_or_else(|| {
            CliError(format!(
                "This device's secret is not in the system key store, so the link book in {} cannot be used. Remove the file to start again.",
                self.path.display()
            ))
        })?;
        book.insert(
            "seed".into(),
            serde_json::from_str(&seed).map_err(|_| damaged())?,
        );
        serde_json::to_vec(&book).map(Some).map_err(|_| damaged())
    }

    /// Writes the book whole: the seed to the key store, then the rest to a private temporary file and a
    /// rename, so a crash never leaves half.
    pub fn save(&self, bytes: &[u8]) -> Result<()> {
        use std::io::Write;
        let mut book: serde_json::Map<String, serde_json::Value> = serde_json::from_slice(bytes)
            .map_err(|_| CliError("The link book could not be saved.".into()))?;
        let seed = book
            .remove("seed")
            .and_then(|s| serde_json::to_string(&s).ok())
            .ok_or_else(|| CliError("The link book could not be saved.".into()))?;
        if self.seeds.get().map_err(CliError)?.as_deref() != Some(seed.as_str()) {
            self.seeds.set(&seed).map_err(CliError)?;
        }
        let rest = serde_json::to_vec(&book)
            .map_err(|_| CliError("The link book could not be saved.".into()))?;
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let temporary = self.path.with_extension("new");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&rest)?;
        file.sync_all()?;
        std::fs::rename(&temporary, &self.path)?;
        Ok(())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// A new device id for a first run.
pub fn new_device_id() -> Uuid {
    Uuid::from_bytes(rand::random())
}

/// What a connection task tells the loop.
enum Input {
    Accepted {
        stream: TcpStream,
        via_hop: bool,
        leftover: Vec<u8>,
    },
    Data(ConnId, Vec<u8>),
    Closed(ConnId),
    Dialed {
        device: Uuid,
        stream: TcpStream,
        via_hop: bool,
        leftover: Vec<u8>,
    },
    DialFailed(Uuid),
    HopRejected,
}

type Save = Box<dyn FnMut(&[u8]) -> std::result::Result<(), String> + Send>;
type Job = Box<dyn FnOnce(&mut Node, Time) + Send>;

/// A node running on sockets. Ask it things with `with`, and read what happened from the events channel.
pub struct Runner {
    jobs: mpsc::UnboundedSender<Job>,
    stop: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl Runner {
    /// Starts `node` on `listener`. `events` gets every event the node raises. `save` stores the book each
    /// time the node asks for it.
    pub fn start(
        mut node: Node,
        listener: TcpListener,
        events: mpsc::UnboundedSender<Event>,
        save: impl FnMut(&[u8]) -> std::result::Result<(), String> + Send + 'static,
    ) -> Result<Self> {
        node.set_port(Some(listener.local_addr()?.port()));
        let (jobs, job_rx) = mpsc::unbounded_channel();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(drive(
            node,
            listener,
            events,
            Box::new(save),
            job_rx,
            stopped,
        ));
        Ok(Self {
            jobs,
            stop: Some(stop),
            task,
        })
    }

    /// Runs `job` on the node and gives back what it returns. None when the runner has stopped.
    pub async fn with<T: Send + 'static>(
        &self,
        job: impl FnOnce(&mut Node, Time) -> T + Send + 'static,
    ) -> Option<T> {
        let (answer, reply) = oneshot::channel();
        let job: Job = Box::new(move |node, now| {
            let _ = answer.send(job(node, now));
        });
        self.jobs.send(job).ok()?;
        reply.await.ok()
    }

    /// Stops the node (every connection closes) and waits for it.
    pub async fn stop(mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = self.task.await;
    }
}

struct Sockets {
    inputs: mpsc::UnboundedSender<Input>,
    writers: HashMap<ConnId, (mpsc::UnboundedSender<Vec<u8>>, JoinHandle<()>)>,
    hop: Option<JoinHandle<()>>,
    events: mpsc::UnboundedSender<Event>,
    save: Save,
}

async fn drive(
    mut node: Node,
    listener: TcpListener,
    events: mpsc::UnboundedSender<Event>,
    save: Save,
    mut jobs: mpsc::UnboundedReceiver<Job>,
    mut stopped: oneshot::Receiver<()>,
) {
    let (inputs, mut input_rx) = mpsc::unbounded_channel();
    let mut sockets = Sockets {
        inputs,
        writers: HashMap::new(),
        hop: None,
        events,
        save,
    };
    node.start(now());
    sockets.restart_hop(&node);
    let mut ticker = tokio::time::interval(Duration::from_secs(1));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        sockets.flush(&mut node);
        tokio::select! {
            _ = &mut stopped => break,
            job = jobs.recv() => match job {
                Some(job) => job(&mut node, now()),
                None => break,
            },
            input = input_rx.recv() => {
                if let Some(input) = input {
                    sockets.handle(&mut node, input);
                }
            }
            accepted = listener.accept() => {
                if let Ok((stream, _)) = accepted {
                    sockets.accept(&mut node, stream, false, Vec::new());
                }
            }
            _ = ticker.tick() => node.tick(now()),
        }
    }
    node.stop(now());
    sockets.flush(&mut node);
    if let Some(hop) = sockets.hop.take() {
        hop.abort();
    }
}

impl Sockets {
    fn handle(&mut self, node: &mut Node, input: Input) {
        match input {
            Input::Accepted {
                stream,
                via_hop,
                leftover,
            } => self.accept(node, stream, via_hop, leftover),
            Input::Data(conn, bytes) => node.received(conn, &bytes, now()),
            Input::Closed(conn) => {
                if self.writers.contains_key(&conn) {
                    self.drop_connection(conn);
                    node.closed(conn, now());
                }
            }
            Input::Dialed {
                device,
                stream,
                via_hop,
                leftover,
            } => {
                if let Some(conn) = node.dialed(device, via_hop, now()) {
                    self.attach(node, conn, stream, leftover);
                }
            }
            Input::DialFailed(device) => node.dial_failed(device, now()),
            Input::HopRejected => node.hop_rejected(),
        }
    }

    fn accept(&mut self, node: &mut Node, stream: TcpStream, via_hop: bool, leftover: Vec<u8>) {
        if let Some(conn) = node.accepted(via_hop, now()) {
            self.attach(node, conn, stream, leftover);
        }
    }

    /// Starts reading and writing a connection the node knows.
    fn attach(&mut self, node: &mut Node, conn: ConnId, stream: TcpStream, leftover: Vec<u8>) {
        let _ = stream.set_nodelay(true);
        let (mut read, mut write) = stream.into_split();
        let (to_write, mut queued) = mpsc::unbounded_channel::<Vec<u8>>();
        let writer = tokio::spawn(async move {
            while let Some(bytes) = queued.recv().await {
                if write.write_all(&bytes).await.is_err() {
                    break;
                }
            }
            let _ = write.shutdown().await;
        });
        let inputs = self.inputs.clone();
        let reader = tokio::spawn(async move {
            let mut buffer = vec![0u8; 16 * 1024];
            loop {
                match read.read(&mut buffer).await {
                    Ok(n) if n > 0 => {
                        if inputs
                            .send(Input::Data(conn, buffer[..n].to_vec()))
                            .is_err()
                        {
                            return;
                        }
                    }
                    _ => {
                        let _ = inputs.send(Input::Closed(conn));
                        return;
                    }
                }
            }
        });
        // The reader is what is aborted on close. The writer ends when its queue is dropped.
        drop(writer);
        self.writers.insert(conn, (to_write, reader));
        if !leftover.is_empty() {
            node.received(conn, &leftover, now());
        }
    }

    fn drop_connection(&mut self, conn: ConnId) {
        if let Some((_, reader)) = self.writers.remove(&conn) {
            reader.abort();
        }
    }

    /// Carries out what the node asked for.
    fn flush(&mut self, node: &mut Node) {
        loop {
            let outputs = node.drain();
            if outputs.is_empty() {
                return;
            }
            for output in outputs {
                match output {
                    Output::Send { conn, bytes } => {
                        if let Some((writer, _)) = self.writers.get(&conn) {
                            let _ = writer.send(bytes);
                        }
                    }
                    Output::Close { conn } => self.drop_connection(conn),
                    Output::Dial(request) => {
                        tokio::spawn(dial(request, self.inputs.clone()));
                    }
                    Output::Save(bytes) => {
                        if let Err(why) = (self.save)(&bytes) {
                            node.save_failed(&why);
                        }
                    }
                    // The node closes the connections it no longer wants by itself, and a new door key
                    // takes effect on the next handshake, so the open listener stays.
                    Output::Relisten => {}
                    Output::HopChanged => self.restart_hop(node),
                    Output::Event(event) => {
                        let _ = self.events.send(event);
                    }
                }
            }
        }
    }

    fn restart_hop(&mut self, node: &Node) {
        if let Some(old) = self.hop.take() {
            old.abort();
        }
        if let Some((address, credentials, _)) = node.hop_host() {
            self.hop = Some(tokio::spawn(wait_at_hop(
                address,
                credentials,
                self.inputs.clone(),
            )));
        }
    }
}

/// Tries the device's addresses, then its Hop.
async fn dial(request: DialRequest, inputs: mpsc::UnboundedSender<Input>) {
    let device = request.device;
    let card = request.card;
    for host in &card.routes.hosts {
        let connect = TcpStream::connect((host.as_str(), card.routes.port));
        if let Ok(Ok(stream)) = tokio::time::timeout(CONNECT_TIMEOUT, connect).await {
            let _ = inputs.send(Input::Dialed {
                device,
                stream,
                via_hop: false,
                leftover: Vec::new(),
            });
            return;
        }
    }
    if let Some((address, credentials)) = hop_route(&card)
        && let Ok((stream, leftover)) = through_hop(&address, credentials, GUEST_WAIT).await
    {
        let _ = inputs.send(Input::Dialed {
            device,
            stream,
            via_hop: true,
            leftover,
        });
        return;
    }
    let _ = inputs.send(Input::DialFailed(device));
}

/// The Hop in a card, with the credentials of a guest of its room.
fn hop_route(card: &LinkCard) -> Option<(HopAddress, HopCredentials)> {
    let address = HopAddress::parse(card.routes.hop.as_deref()?)?;
    let room = card.device.room.0.as_slice().try_into().ok()?;
    let door = card.door.0.as_slice().try_into().ok()?;
    Some((address, HopCredentials::guest(room, &door)))
}

/// Why a Hop connection gave no splice.
enum HopFailure {
    /// The Hop turned the proof away.
    Rejected,
    /// Nobody came before the wait ran out. Not an error.
    Nobody,
    /// The Hop is busy, unreachable or did not speak the protocol.
    Unavailable,
}

/// Does the Hop's handshake on a new connection. On `go` the stream carries the link's bytes, and
/// `leftover` holds what followed the status byte.
async fn through_hop(
    address: &HopAddress,
    credentials: HopCredentials,
    wait: Duration,
) -> std::result::Result<(TcpStream, Vec<u8>), HopFailure> {
    let attempt = async {
        let mut stream = tokio::time::timeout(
            CONNECT_TIMEOUT,
            TcpStream::connect((address.host.as_str(), address.port)),
        )
        .await
        .map_err(|_| HopFailure::Unavailable)?
        .map_err(|_| HopFailure::Unavailable)?;
        let mut client = HopClient::new(credentials);
        stream
            .write_all(&client.hello())
            .await
            .map_err(|_| HopFailure::Unavailable)?;
        let mut buffer = [0u8; 512];
        loop {
            let n = stream
                .read(&mut buffer)
                .await
                .map_err(|_| HopFailure::Unavailable)?;
            if n == 0 {
                return Err(match client.closed() {
                    Some(HopStatus::Rejected) => HopFailure::Rejected,
                    _ => HopFailure::Unavailable,
                });
            }
            let progress = client
                .feed(&buffer[..n])
                .map_err(|_| HopFailure::Unavailable)?;
            if !progress.reply.is_empty() {
                stream
                    .write_all(&progress.reply)
                    .await
                    .map_err(|_| HopFailure::Unavailable)?;
            }
            match progress.status {
                Some(HopStatus::Go) => return Ok((stream, progress.rest)),
                Some(HopStatus::Rejected) => return Err(HopFailure::Rejected),
                Some(HopStatus::Nobody) => return Err(HopFailure::Nobody),
                Some(HopStatus::Busy) => return Err(HopFailure::Unavailable),
                None => {}
            }
        }
    };
    tokio::time::timeout(wait, attempt)
        .await
        .map_err(|_| HopFailure::Nobody)?
}

/// Keeps one connection waiting in this device's room. Each guest that is spliced in is handed to the loop,
/// and a new waiting connection takes its place.
async fn wait_at_hop(
    address: HopAddress,
    credentials: HopCredentials,
    inputs: mpsc::UnboundedSender<Input>,
) {
    let mut pause = RETRY_FIRST;
    loop {
        let started = tokio::time::Instant::now();
        match through_hop(&address, credentials.clone(), HOST_WAIT).await {
            Ok((stream, leftover)) => {
                pause = RETRY_FIRST;
                let accepted = Input::Accepted {
                    stream,
                    via_hop: true,
                    leftover,
                };
                if inputs.send(accepted).is_err() {
                    return;
                }
            }
            Err(HopFailure::Nobody) => {
                pause = RETRY_FIRST;
                // A wait that ends at once is too fast to trust: do not ask again in a tight loop.
                if let Some(rest) = RETRY_FIRST.checked_sub(started.elapsed()) {
                    tokio::time::sleep(rest).await;
                }
            }
            Err(HopFailure::Rejected) => {
                if inputs.send(Input::HopRejected).is_err() {
                    return;
                }
                tokio::time::sleep(RETRY_LONGEST).await;
            }
            Err(HopFailure::Unavailable) => {
                tokio::time::sleep(pause).await;
                pause = (pause * 2).min(RETRY_LONGEST);
            }
        }
    }
}

/// A host name or address other devices can use to reach this one on the local network. Nothing is
/// sent: the system only picks the address it would use to go out. None when it has none.
pub fn local_address() -> Option<String> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("192.0.2.1:9").ok()?;
    let address = socket.local_addr().ok()?.ip();
    (!address.is_unspecified() && !address.is_loopback()).then(|| address.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use imp_core::link::book::LinkBook;
    use std::sync::Mutex;

    #[derive(Default)]
    struct Memory(Mutex<Option<String>>);

    impl SeedStore for Memory {
        fn get(&self) -> std::result::Result<Option<String>, String> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn set(&self, seed: &str) -> std::result::Result<(), String> {
            *self.0.lock().unwrap() = Some(seed.to_string());
            Ok(())
        }
    }

    struct Missing;

    impl SeedStore for Missing {
        fn get(&self) -> std::result::Result<Option<String>, String> {
            Err(no_key_store())
        }
        fn set(&self, _: &str) -> std::result::Result<(), String> {
            Err(no_key_store())
        }
    }

    fn folder(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("imp-book-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    /// A Hop that follows the handshake and answers each connection with the next scripted status. A
    /// connection with no status left stays open and silent. It records the role of every hello.
    async fn fake_hop(script: Vec<Option<u8>>) -> (HopAddress, Arc<Mutex<Vec<u8>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = HopAddress::new("127.0.0.1", listener.local_addr().unwrap().port()).unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            let mut script = script.into_iter();
            while let Ok((mut stream, _)) = listener.accept().await {
                let status = script.next().flatten();
                let log = log.clone();
                tokio::spawn(async move {
                    let mut hello = [0u8; imp_core::link::hop::HELLO_LEN];
                    stream.read_exact(&mut hello).await.unwrap();
                    log.lock().unwrap().push(hello[6]);
                    stream.write_all(&[7u8; 32]).await.unwrap();
                    let mut proof = [0u8; 64];
                    stream.read_exact(&mut proof).await.unwrap();
                    if let Some(byte) = status {
                        stream.write_all(&[byte, 42]).await.unwrap();
                    }
                    let mut rest = Vec::new();
                    let _ = stream.read_to_end(&mut rest).await;
                });
            }
        });
        (address, seen)
    }

    fn host_credentials() -> HopCredentials {
        let identity = imp_core::link::identity::Identity::new(
            Uuid::from_u128(1),
            "Mac",
            imp_core::link::card::LinkKind::Mac,
        );
        HopCredentials::host(&identity, &[3u8; 32])
    }

    fn guest_credentials() -> HopCredentials {
        HopCredentials::guest([5u8; 32], &[3u8; 32])
    }

    async fn failure(address: &HopAddress) -> HopFailure {
        match through_hop(address, guest_credentials(), Duration::from_secs(5)).await {
            Ok(_) => panic!("the Hop should not have spliced"),
            Err(why) => why,
        }
    }

    #[tokio::test]
    async fn a_guest_the_hop_splices_gets_the_link_bytes_that_followed_the_status() {
        let (address, seen) = fake_hop(vec![Some(0)]).await;
        let Ok((_stream, leftover)) =
            through_hop(&address, guest_credentials(), Duration::from_secs(5)).await
        else {
            panic!("the guest was not spliced");
        };
        assert_eq!(leftover, vec![42]);
        assert_eq!(*seen.lock().unwrap(), vec![2]);
    }

    #[tokio::test]
    async fn a_guest_with_nobody_waiting_gives_up_for_now() {
        let (address, _) = fake_hop(vec![Some(3)]).await;
        assert!(matches!(failure(&address).await, HopFailure::Nobody));
        // A Hop that never answers is the same: the wait runs out.
        let (silent, _) = fake_hop(vec![None]).await;
        let waited = through_hop(&silent, guest_credentials(), Duration::from_millis(200)).await;
        assert!(matches!(waited, Err(HopFailure::Nobody)));
    }

    #[tokio::test]
    async fn a_guest_the_hop_rejects_or_finds_busy_is_told_so() {
        let (address, _) = fake_hop(vec![Some(1), Some(2)]).await;
        assert!(matches!(failure(&address).await, HopFailure::Rejected));
        assert!(matches!(failure(&address).await, HopFailure::Unavailable));
        let nothing = HopAddress::new("127.0.0.1", 1).unwrap();
        assert!(matches!(failure(&nothing).await, HopFailure::Unavailable));
    }

    #[tokio::test]
    async fn a_host_keeps_waiting_after_nobody_came() {
        let (address, seen) = fake_hop(vec![Some(3)]).await;
        let (inputs, _held) = mpsc::unbounded_channel();
        let waiting = tokio::spawn(wait_at_hop(address, host_credentials(), inputs));
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while seen.lock().unwrap().len() < 2 {
            assert!(tokio::time::Instant::now() < deadline, "no second wait");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert_eq!(*seen.lock().unwrap(), vec![1, 1]);
        waiting.abort();
    }

    #[tokio::test]
    async fn a_host_the_hop_rejects_says_so_and_a_spliced_guest_is_handed_over() {
        let (address, _) = fake_hop(vec![Some(1)]).await;
        let (inputs, mut events) = mpsc::unbounded_channel();
        let waiting = tokio::spawn(wait_at_hop(address, host_credentials(), inputs));
        let first = tokio::time::timeout(Duration::from_secs(5), events.recv()).await;
        assert!(matches!(first, Ok(Some(Input::HopRejected))));
        waiting.abort();

        let (address, _) = fake_hop(vec![Some(0)]).await;
        let (inputs, mut events) = mpsc::unbounded_channel();
        let waiting = tokio::spawn(wait_at_hop(address, host_credentials(), inputs));
        let first = tokio::time::timeout(Duration::from_secs(5), events.recv()).await;
        let Ok(Some(Input::Accepted {
            via_hop, leftover, ..
        })) = first
        else {
            panic!("the guest was not handed over");
        };
        assert!(via_hop);
        assert_eq!(leftover, vec![42]);
        waiting.abort();
    }

    #[test]
    fn the_seed_goes_to_the_key_store_and_never_into_the_file() {
        let dir = folder("seed");
        let store = Arc::new(Memory::default());
        let file = BookFile::in_dir(&dir, store.clone());
        assert!(file.load().unwrap().is_none());
        let book = LinkBook::new(Uuid::from_u128(5), [0x5a; 32], [7; 32]);
        let whole = book.write();
        file.save(&whole).unwrap();
        let on_disk = std::fs::read_to_string(file.path()).unwrap();
        assert!(!on_disk.contains("seed"), "{on_disk}");
        assert!(
            store
                .0
                .lock()
                .unwrap()
                .as_deref()
                .is_some_and(|s| !s.is_empty())
        );
        let seed_text = store.0.lock().unwrap().clone().unwrap();
        assert!(!on_disk.contains(seed_text.trim_matches('"')));
        let back = LinkBook::read(&file.load().unwrap().unwrap()).unwrap();
        assert_eq!(back, book);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn with_no_key_store_it_says_what_to_do_and_writes_nothing() {
        let dir = folder("missing");
        let file = BookFile::in_dir(&dir, Arc::new(Missing));
        let said = file.load().unwrap_err().0;
        assert!(said.contains("system key store"), "{said}");
        assert!(said.contains("Secret Service"), "{said}");
        let book = LinkBook::new(Uuid::from_u128(5), [1; 32], [2; 32]).write();
        assert!(file.save(&book).is_err());
        assert!(!file.path().exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_book_whose_secret_is_gone_is_not_used() {
        let dir = folder("gone");
        let file = BookFile::in_dir(&dir, Arc::new(Memory::default()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(file.path(), b"{\"device\":\"x\"}").unwrap();
        assert!(
            file.load()
                .unwrap_err()
                .0
                .contains("not in the system key store")
        );
        std::fs::write(file.path(), b"{\"seed\":\"AAAA\"}").unwrap();
        assert!(file.load().unwrap_err().0.contains("cannot be used"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
