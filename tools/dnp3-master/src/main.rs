//! usage: dnp3-master HOST:PORT MASTER_ADDR OUTSTATION_ADDR read
//!        dnp3-master HOST:PORT MASTER_ADDR OUTSTATION_ADDR crob INDEX on|off [direct|sbo]
//! `read` does an integrity (class 0) poll and prints the static (non-event) binary inputs, binary output statuses and analog inputs.
//! `crob` sends one g12v1 control (latch on/off) to binary output INDEX and prints the outstation's command status.
use dnp3::app::control::{Group12Var1, OpType};
use dnp3::app::measurement::{AnalogInput, BinaryInput, BinaryOutputStatus};
use dnp3::app::*;
use dnp3::decode::DecodeLevel;
use dnp3::link::*;
use dnp3::master::*;
use dnp3::tcp::*;
use std::time::Duration;

struct Quiet;
impl AssociationHandler for Quiet {}
impl AssociationInformation for Quiet {}
struct Print;
impl ReadHandler for Print {
    fn handle_binary_input(&mut self, h: HeaderInfo, it: &mut dyn Iterator<Item = (BinaryInput, u16)>) {
        for (v, i) in it.filter(|_| !h.is_event) { println!("binary-input {i} {}", v.value as u8); }
    }
    fn handle_binary_output_status(&mut self, h: HeaderInfo, it: &mut dyn Iterator<Item = (BinaryOutputStatus, u16)>) {
        for (v, i) in it.filter(|_| !h.is_event) { println!("binary-output {i} {}", v.value as u8); }
    }
    fn handle_analog_input(&mut self, h: HeaderInfo, it: &mut dyn Iterator<Item = (AnalogInput, u16)>) {
        for (v, i) in it.filter(|_| !h.is_event) { println!("analog-input {i} {}", v.value); }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 5 { return Err("usage: dnp3-master HOST:PORT MASTER OUTSTATION read|crob INDEX on|off [direct|sbo]".into()); }
    let (master, outstation) = (EndpointAddress::try_new(a[2].parse()?)?, EndpointAddress::try_new(a[3].parse()?)?);
    let mut cfg = MasterChannelConfig::new(master);
    cfg.decode_level = DecodeLevel::nothing();
    let mut channel = spawn_master_tcp_client(
        LinkErrorMode::Close, cfg, EndpointList::new(a[1].clone(), &[]),
        ConnectStrategy::default(), NullListener::create());
    let mut assoc = channel
        .add_association(outstation, AssociationConfig::quiet(), Box::new(Print), Box::new(Quiet),
                         Box::new(Quiet))
        .await?;
    channel.enable().await?;
    let work = async {
        match a[4].as_str() {
            "read" => assoc.read(ReadRequest::ClassScan(Classes::all())).await.map_err(|e| format!("read: {e}")),
            "crob" => {
                let idx: u16 = a[5].parse().map_err(|_| "bad INDEX")?;
                let op = match a[6].as_str() { "on" => OpType::LatchOn, "off" => OpType::LatchOff, _ => return Err("on|off".into()) };
                let mode = if a.get(7).map(String::as_str) == Some("sbo") { CommandMode::SelectBeforeOperate } else { CommandMode::DirectOperate };
                let cmd = CommandBuilder::single_header_u16(Group12Var1::from_op_type(op), idx);
                assoc.operate(mode, cmd).await.map(|_| println!("crob {idx} {} ok", a[6])).map_err(|e| format!("crob: {e}"))
            }
            _ => Err("read|crob".into()),
        }
    };
    tokio::time::timeout(Duration::from_secs(15), work).await.map_err(|_| "timeout")??;
    Ok(())
}
