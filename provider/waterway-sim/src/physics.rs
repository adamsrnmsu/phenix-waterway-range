//! Pure waterway-lock physics. No IO, no clock: `step` advances state by dt seconds.
//!
//! Geometry (metres along the waterway): lower approach [0,100], lock (100,200],
//! upper approach (200,300]. Lower gate at x=100, upper gate at x=200.
//! boat.direction +1 = heading upstream (lower -> upper), -1 = downstream.
//! ponytail: constant speeds, one boat, no hydraulics; tune via `Params`.

pub const LOWER_GATE_X: f64 = 100.0;
pub const UPPER_GATE_X: f64 = 200.0;
pub const END_X: f64 = 300.0;
/// Standoff when a boat moving down is held at a closed gate (keeps it in the zone it came from).
const EPS: f64 = 1e-3;

#[derive(Clone, Copy, Debug)]
pub struct Params {
    pub lower_pool: f64,
    pub upper_pool: f64,
    pub fill_rate: f64, // m/s lock level change with one valve open
    pub boat_speed: f64, // m/s
}
impl Default for Params {
    fn default() -> Self {
        Params { lower_pool: 5.0, upper_pool: 15.0, fill_rate: 0.5, boat_speed: 5.0 }
    }
}

/// Inputs written by the RTUs (UpdatePoints). Latched between updates.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Inputs {
    pub lowergate: bool,
    pub lowervalve: bool,
    pub uppergate: bool,
    pub uppervalve: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct State {
    pub lock_height: f64,
    pub boat_x: f64,
    pub boat_dir: f64, // +1 / -1
}

impl State {
    pub fn new(p: &Params) -> Self {
        State { lock_height: p.lower_pool, boat_x: 0.0, boat_dir: 1.0 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Value {
    Bool(bool),
    Double(f64),
}

fn move_toward(cur: f64, target: f64, max: f64) -> f64 {
    let d = target - cur;
    if d.abs() <= max { target } else { cur + max * d.signum() }
}

pub fn step(s: &mut State, i: &Inputs, p: &Params, dt: f64) {
    // lock level: toward the pool whose valve is open (both open = no net flow)
    if i.lowervalve != i.uppervalve {
        let target = if i.lowervalve { p.lower_pool } else { p.upper_pool };
        s.lock_height = move_toward(s.lock_height, target, p.fill_rate * dt);
    }

    // boat: advance, blocked by closed gates, reverse at the ends
    let x = s.boat_x;
    let mut nx = x + s.boat_dir * p.boat_speed * dt;
    for (gx, open) in [(LOWER_GATE_X, i.lowergate), (UPPER_GATE_X, i.uppergate)] {
        if open {
            continue;
        }
        if s.boat_dir > 0.0 && x <= gx && nx > gx {
            nx = gx;
        } else if s.boat_dir < 0.0 && x > gx && nx <= gx {
            nx = gx + EPS;
        }
    }
    if nx >= END_X {
        nx = END_X;
        s.boat_dir = -1.0;
    } else if nx <= 0.0 {
        nx = 0.0;
        s.boat_dir = 1.0;
    }
    s.boat_x = nx;
}

/// Which sensor zone the boat is in: 0 lower, 1 lock, 2 upper.
fn zone(x: f64) -> usize {
    if x <= LOWER_GATE_X { 0 } else if x <= UPPER_GATE_X { 1 } else { 2 }
}

// bennu field devices declare every tag analog (std::get<double>); a BOOLEAN from the provider aborts them
fn b2d(b: bool) -> f64 { b as u8 as f64 }

/// Value of a published tag, or None if unknown.
pub fn read_point(tag: &str, s: &State, i: &Inputs, p: &Params) -> Option<Value> {
    use Value::*;
    let z = zone(s.boat_x);
    let sensor_active = |k: usize| z == k;
    let sensor_dir = |k: usize| if z == k { s.boat_dir } else { 0.0 };
    Some(match tag {
        "lowerwater.height" => Double(p.lower_pool),
        "upperwater.height" => Double(p.upper_pool),
        "lock.height" => Double(s.lock_height),
        "lowergate.open" => Double(b2d(i.lowergate)),
        "lowervalve.open" => Double(b2d(i.lowervalve)),
        "uppergate.open" => Double(b2d(i.uppergate)),
        "uppervalve.open" => Double(b2d(i.uppervalve)),
        "boat.direction" => Double(s.boat_dir),
        "boat.location" => Double(s.boat_x),
        "lowersensor.direction" => Double(sensor_dir(0)),
        "locksensor.direction" => Double(sensor_dir(1)),
        "uppersensor.direction" => Double(sensor_dir(2)),
        "lowersensor.active" => Double(b2d(sensor_active(0))),
        "locksensor.active" => Double(b2d(sensor_active(1))),
        "uppersensor.active" => Double(b2d(sensor_active(2))),
        _ => return None,
    })
}

/// Input tag -> mutate. Returns false if tag is not an input.
pub fn write_input(tag: &str, v: f64, i: &mut Inputs) -> bool {
    let b = v != 0.0;
    match tag {
        "lowergate.open" => i.lowergate = b,
        "lowervalve.open" => i.lowervalve = b,
        "uppergate.open" => i.uppergate = b,
        "uppervalve.open" => i.uppervalve = b,
        _ => return false,
    }
    true
}

/// The RTU control logic from waterway-scenario.yaml, evaluated from published sensors.
/// Used by tests to close the loop (the real RTUs do this over Modbus).
#[cfg(test)]
pub fn rtu_logic(s: &State, i: &Inputs, p: &Params) -> Inputs {
    let g = |t| match read_point(t, s, i, p) { Some(Value::Double(d)) => d, Some(Value::Bool(b)) => b as u8 as f64, None => 0.0 };
    let (lo, up, lk) = (g("lowerwater.height"), g("upperwater.height"), g("lock.height"));
    let (ld, ldir, ud) = (g("lowersensor.direction"), g("locksensor.direction"), g("uppersensor.direction"));
    let (la, lka, ua) = (g("lowersensor.active") == 1.0, g("locksensor.active") == 1.0, g("uppersensor.active") == 1.0);
    let near = |a: f64| lk >= a - 0.1 && lk <= a + 0.1;
    Inputs {
        lowergate: (ld == 1.0 && la && near(lo)) || (ldir == -1.0 && lka && near(lo)),
        lowervalve: (ld == 1.0 && la && lk > lo) || (ldir == -1.0 && lka && lk > lo),
        uppergate: (ldir == 1.0 && lka && near(up)) || (ud == -1.0 && ua && near(up)),
        uppervalve: (ldir == 1.0 && lka && lk < up) || (ud == -1.0 && ua && lk < up),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_transit_with_rtu_logic() {
        let p = Params::default();
        let mut s = State::new(&p);
        let mut i = Inputs::default();
        let dt = 0.05;
        let (mut reached_upper, mut back_down, mut max_lock) = (false, false, 0.0f64);
        for _ in 0..(600.0 / dt) as usize {
            i = rtu_logic(&s, &i, &p);
            step(&mut s, &i, &p, dt);
            max_lock = max_lock.max(s.lock_height);
            if s.boat_x >= END_X { reached_upper = true; }
            if reached_upper && s.boat_x <= 0.0 { back_down = true; break; }
        }
        assert!(reached_upper, "boat never reached the upper end");
        assert!(back_down, "boat never returned to the lower end");
        assert!((max_lock - p.upper_pool).abs() < 1e-9, "lock never filled to upper pool: {max_lock}");
        assert!((s.lock_height - p.lower_pool).abs() < 0.2, "lock not drained: {}", s.lock_height);
    }

    #[test]
    fn closed_gates_block_boat_and_valve_moves_level() {
        let p = Params::default();
        let mut s = State::new(&p);
        let i = Inputs::default();
        for _ in 0..1000 { step(&mut s, &i, &p, 0.1); }
        assert_eq!(s.boat_x, LOWER_GATE_X); // held at closed lower gate, still lower zone
        assert_eq!(read_point("lowersensor.active", &s, &i, &p), Some(Value::Double(1.0)));
        let i = Inputs { uppervalve: true, ..Default::default() };
        step(&mut s, &i, &p, 1.0);
        assert!((s.lock_height - 5.5).abs() < 1e-9);
    }

    #[test]
    fn boat_reverses_at_ends() {
        let p = Params::default();
        let all = Inputs { lowergate: true, uppergate: true, ..Default::default() };
        let mut s = State::new(&p);
        for _ in 0..70 { step(&mut s, &all, &p, 1.0); } // 350 m at 5 m/s: past the top end
        assert_eq!(s.boat_dir, -1.0);
        assert!(s.boat_x < END_X);
    }
}
