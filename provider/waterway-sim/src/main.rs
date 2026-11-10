//! simulinksolver: drop-in for the Simulink-generated solver, speaking the modelHooks.c contract.
//! Args (-tf inf, -v, ...) are accepted and ignored. See CONTRACT.md.

mod contract;
mod ipc;
mod physics;

use contract::*;
use physics::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn on_signal(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

/// Default tag set when ./publishPoints.txt is absent (same order as injects/publishPoints.txt).
const DEFAULT_POINTS: &str = "lowerwater.height\nlock.height\nupperwater.height\nlowergate.open\nlowervalve.open\nuppergate.open\nuppervalve.open\nboat.direction\nlowersensor.direction\nlocksensor.direction\nuppersensor.direction\nboat.location\nlowersensor.active\nlocksensor.active\nuppersensor.active\n";
const DT: f64 = 0.05; // fixed step, real time

fn die(msg: &str, e: std::io::Error) -> ! {
    println!("Fatal: {msg}: {e}");
    std::process::exit(1);
}

fn main() {
    // all args ignored (-tf inf etc.); -h only for humans
    if std::env::args().any(|a| a == "-h" || a == "--help") {
        println!("simulinksolver [-tf inf ...]  waterway lock simulator (modelHooks shm/semaphore contract)");
        return;
    }
    unsafe {
        libc::signal(libc::SIGINT, on_signal as *const () as usize);
        libc::signal(libc::SIGTERM, on_signal as *const () as usize);
    }

    let text = std::fs::read_to_string("publishPoints.txt").unwrap_or_else(|_| {
        println!("Info: publishPoints.txt not found in cwd, using built-in waterway point list");
        DEFAULT_POINTS.to_string()
    });
    let points = parse_publish_points(&text);
    println!("Info: Read {} PublishPoints", points.len());

    // init order exactly as modelHooks.c init(): semaphores (locked) -> FIFO -> count shm -> points shm -> publish -> unlock
    let publish_sem = ipc::Sem::open_locked(PUBLISH_SEM).unwrap_or_else(|e| die("publish semaphore", e));
    let updates_sem = ipc::Sem::open_locked(UPDATES_SEM).unwrap_or_else(|e| die("updates semaphore", e));
    let fifo = ipc::Fifo::create().unwrap_or_else(|e| die("updates FIFO", e));
    let count_shm = ipc::Shm::create(NUM_PUBLISH_POINTS_SHM_KEY, 4).unwrap_or_else(|e| die("count shm", e));
    count_shm.zero();
    count_shm.write(0, &encode_count(points.len()));
    let points_shm = ipc::Shm::create(PUBLISH_POINTS_SHM_KEY, points.len() * MAX_MSG_LEN).unwrap_or_else(|e| die("points shm", e));
    points_shm.zero();

    let params = Params::default();
    let mut state = State::new(&params);
    let mut inputs = Inputs::default();
    let publish = |s: &State, i: &Inputs| {
        for (n, tag) in points.iter().enumerate() {
            let v = read_point(tag, s, i, &params).unwrap_or(Value::Double(0.0));
            points_shm.write(n * MAX_MSG_LEN, &encode_dto(tag, v));
        }
    };
    publish(&state, &inputs);
    publish_sem.post();
    updates_sem.post();
    println!("Info: waterway solver running (dt={DT}s)");

    let t0 = Instant::now();
    let mut k: u64 = 0;
    while !STOP.load(Ordering::SeqCst) {
        // step() hook: publish, then apply updates, then advance the model
        publish_sem.wait();
        publish(&state, &inputs);
        publish_sem.post();

        updates_sem.wait();
        for rec in fifo.drain() {
            match decode_update(&rec) {
                Some((tag, v)) => {
                    if !write_input(&tag, v, &mut inputs) {
                        println!("update for unknown/readonly tag {tag} ignored");
                    }
                }
                None => println!("Warn: malformed update record ignored"),
            }
        }
        updates_sem.post();

        step(&mut state, &inputs, &params, DT);
        k += 1;
        let due = t0 + Duration::from_secs_f64(k as f64 * DT);
        if let Some(d) = due.checked_duration_since(Instant::now()) {
            std::thread::sleep(d);
        }
    }

    // term(): take both locks so the provider is not mid-read, then tear everything down
    println!("Info: Model termination");
    publish_sem.wait();
    updates_sem.wait();
    count_shm.destroy();
    points_shm.destroy();
    publish_sem.destroy();
    updates_sem.destroy();
    fifo.destroy();
}
