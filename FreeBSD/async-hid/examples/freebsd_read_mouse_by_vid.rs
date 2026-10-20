// Reads a few input reports from a specific mouse VID (first arg, hex).
// Usage: freebsd_read_mouse_by_vid <vid_hex>  e.g. 30fa
//
// Useful when multiple mice are attached and you want to target one.

use std::env;

use async_hid::{AsyncHidRead, HidBackend, HidResult};
use futures_lite::stream::StreamExt;
use simple_logger::SimpleLogger;

#[pollster::main]
async fn main() -> HidResult<()> {
    SimpleLogger::new().init().unwrap();

    let want_vid = env::args()
        .nth(1)
        .and_then(|s| u16::from_str_radix(s.trim_start_matches("0x"), 16).ok())
        .expect("pass VID as hex, e.g. 30fa");

    let mut device = HidBackend::default()
        .enumerate()
        .await?
        .find(|info| info.vendor_id == want_vid && info.usage_page == 0x01 && info.usage_id == 0x02)
        .await
        .expect("no matching HID mouse found")
        .open_readable()
        .await?;

    println!("reading 5 reports — move the mouse");
    let mut buffer = [0u8; 64];
    for _ in 0..5 {
        let size = device.read_input_report(&mut buffer).await?;
        println!("-> ({} bytes) {:02x?}", size, &buffer[..size]);
    }
    Ok(())
}
