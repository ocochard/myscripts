// Reads N reports from a specific /dev/hidraw path.
// Usage: freebsd_read_by_path <path> [count]
//
// Prints the report id (byte 0) alongside the payload so you can see the
// numbered-report path being exercised.

use std::env;
use std::path::PathBuf;

use async_hid::{AsyncHidRead, DeviceId, HidBackend, HidResult};
use simple_logger::SimpleLogger;

#[pollster::main]
async fn main() -> HidResult<()> {
    SimpleLogger::new().init().unwrap();

    let path = env::args().nth(1).expect("pass /dev/hidraw? path");
    let count: usize = env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(5);

    let backend = HidBackend::default();
    let id = DeviceId::DevPath(PathBuf::from(&path));

    let device = backend
        .query_devices(&id)
        .await?
        .next()
        .expect("no device at that path");

    println!("device: {} @ {:?}", device.name, device.id);

    let mut r = device.open_readable().await?;
    let mut buf = [0u8; 64];
    for _ in 0..count {
        let n = r.read_input_report(&mut buf).await?;
        let (rid, payload) = if n > 0 { (buf[0], &buf[1..n]) } else { (0, &buf[..0]) };
        println!("-> rid={:#04x} ({} bytes payload) {:02x?}", rid, payload.len(), payload);
    }
    Ok(())
}
