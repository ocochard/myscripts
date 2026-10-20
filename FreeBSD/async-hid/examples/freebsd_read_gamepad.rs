// Reads a few reports from any HID gamepad on FreeBSD.
// Move sticks or press buttons to trigger reports.

use async_hid::{AsyncHidRead, HidBackend, HidResult};
use futures_lite::stream::StreamExt;
use simple_logger::SimpleLogger;

#[pollster::main]
async fn main() -> HidResult<()> {
    SimpleLogger::new().init().unwrap();

    let mut device = HidBackend::default()
        .enumerate()
        .await?
        .find(|info| info.usage_page == 0x01 && info.usage_id == 0x05)
        .await
        .expect("no HID gamepad found")
        .open_readable()
        .await?;

    println!("reading 5 reports — move sticks or press buttons");
    let mut buffer = [0u8; 64];
    for _ in 0..5 {
        let size = device.read_input_report(&mut buffer).await?;
        println!("-> ({} bytes) {:02x?}", size, &buffer[..size]);
    }
    Ok(())
}
