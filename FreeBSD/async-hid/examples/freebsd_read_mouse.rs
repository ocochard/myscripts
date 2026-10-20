// Hardware regression test for the FreeBSD hidraw backend, step 3.
//
// Finds the first HID device on the Generic Desktop / Mouse usage
// (usage_page=0x01, usage_id=0x02), opens it, reads 5 input reports,
// prints them. Move the mouse to trigger reports.

use async_hid::{AsyncHidRead, HidBackend, HidResult};
use futures_lite::stream::StreamExt;
use simple_logger::SimpleLogger;

#[pollster::main]
async fn main() -> HidResult<()> {
    SimpleLogger::new().init().unwrap();

    let mut device = HidBackend::default()
        .enumerate()
        .await?
        .find(|info| info.usage_page == 0x01 && info.usage_id == 0x02)
        .await
        .expect("no HID mouse found — is /dev/hidraw* present and readable?")
        .open_readable()
        .await?;

    println!("reading 5 input reports — move the mouse");
    let mut buffer = [0u8; 64];
    for _ in 0..5 {
        let size = device.read_input_report(&mut buffer).await?;
        println!("-> ({} bytes) {:02x?}", size, &buffer[..size]);
    }
    Ok(())
}
