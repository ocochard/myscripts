// Hardware regression test for the FreeBSD hidraw backend, step 4.
//
// Finds the first HID keyboard (usage_page=0x01, usage_id=0x06), opens it
// read+write, blinks NumLock 3 times using standard boot-protocol output
// reports (1 byte, bit0=NumLock, bit1=CapsLock, bit2=ScrollLock).

use std::time::Duration;

use async_hid::{AsyncHidWrite, HidBackend, HidResult};
use async_io::Timer;
use futures_lite::stream::StreamExt;
use simple_logger::SimpleLogger;

#[pollster::main]
async fn main() -> HidResult<()> {
    SimpleLogger::new().init().unwrap();

    let device = HidBackend::default()
        .enumerate()
        .await?
        .find(|info| info.usage_page == 0x01 && info.usage_id == 0x06)
        .await
        .expect("no HID keyboard found");

    println!("found keyboard: {} at {:?}", device.name, device.id);

    let (_r, mut w) = device.open().await?;

    println!("NumLock ON — LED should be lit for 3s");
    w.write_output_report(&[0x00, 0b0000_0001]).await?;
    Timer::after(Duration::from_secs(3)).await;

    println!("NumLock OFF — LED should be dark for 3s");
    w.write_output_report(&[0x00, 0b0000_0000]).await?;
    Timer::after(Duration::from_secs(3)).await;

    println!("done");
    Ok(())
}
