// Read a feature report from the first HID gamepad.
// Read-only — don't write unknown vendor feature bytes back.

use async_hid::{AsyncHidFeatureHandle, HidBackend, HidResult};
use futures_lite::stream::StreamExt;
use simple_logger::SimpleLogger;

#[pollster::main]
async fn main() -> HidResult<()> {
    SimpleLogger::new().init().unwrap();

    let device = HidBackend::default()
        .enumerate()
        .await?
        .find(|info| info.usage_page == 0x01 && info.usage_id == 0x05)
        .await
        .expect("no HID gamepad found");

    println!("device: {} @ {:?}", device.name, device.id);

    let mut fh = device.open_feature_handle().await?;

    // Report id byte (0 = unnumbered) + 8-byte payload from the descriptor.
    let mut buf = [0u8; 9];
    let n = fh.read_feature_report(&mut buf).await?;
    println!("feature report ({} bytes): {:02x?}", n, &buf[..n]);
    Ok(())
}
