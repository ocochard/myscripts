// Starter skeleton for src/backend/freebsdhid/mod.rs in sidit77/async-hid.
// All methods return Unsupported — step 1 of the plan in
// async-hid-freebsd-backend.md. Fill each in commit-by-commit.
//
// Also needed to wire this in (NOT included here, edit in the crate):
//
//  1. src/backend/mod.rs, inside `dyn_backend_impl!`:
//         #[cfg(target_os = "freebsd")]
//         mod freebsdhid {
//             FreeBsdHid(freebsdhid::FreeBsdHidBackend)
//         }
//
//  2. src/backend/mod.rs, in `Default for DynBackend`:
//         #[cfg(target_os = "freebsd")]
//         { return Self::new(BackendType::FreeBsdHid); }
//
//  3. Cargo.toml (workspace):
//         [target.'cfg(target_os = "freebsd")'.dependencies]
//         nix = { version = "…", features = ["fs", "ioctl", "poll", "event", "socket"] }
//         async-io = "…"

use std::future::Future;
use std::path::PathBuf;

use futures_lite::stream::{iter, Boxed};

use crate::backend::{Backend, DeviceInfoStream};
use crate::traits::{AsyncHidFeatureHandle, AsyncHidRead, AsyncHidWrite};
use crate::{DeviceEvent, DeviceId, DeviceInfo, HidError, HidResult};

#[derive(Default)]
pub struct FreeBsdHidBackend;

pub struct HidDevice {
    // Populated in step 3 (open + read_input_report).
    // Sketch: an async_io::Async<std::os::fd::OwnedFd> plus the DeviceId.
    _path: PathBuf,
}

impl Backend for FreeBsdHidBackend {
    type Reader = HidDevice;
    type Writer = HidDevice;
    type FeatureHandle = HidDevice;

    async fn enumerate(&self) -> HidResult<DeviceInfoStream> {
        // Step 2: walk /dev/hidraw*, ioctl HIDIOCGRAWINFO / HIDIOCGRAWNAME /
        // HIDIOCGRDESC(SIZE), build DeviceInfo per node.
        Ok(iter(std::iter::empty()).boxed())
    }

    fn watch(&self) -> HidResult<Boxed<DeviceEvent>> {
        // Step 6: connect to /var/run/devd.seqpacket.pipe, wrap in Async,
        // parse attach/detach lines for hidraw devices.
        Err(HidError::custom("watch: not yet implemented on FreeBSD"))
    }

    async fn query_info(&self, _id: &DeviceId) -> HidResult<Vec<DeviceInfo>> {
        // Same as enumerate for a single node — factor out.
        Err(HidError::custom("query_info: not yet implemented on FreeBSD"))
    }

    async fn open(
        &self,
        _id: &DeviceId,
        _read: bool,
        _write: bool,
    ) -> HidResult<(Option<Self::Reader>, Option<Self::Writer>)> {
        // Step 3: open /dev/hidraw? with the requested flags, wrap the fd
        // with async_io::Async, return the same handle for reader/writer.
        Err(HidError::custom("open: not yet implemented on FreeBSD"))
    }

    async fn open_feature_handle(&self, _id: &DeviceId) -> HidResult<Self::FeatureHandle> {
        // Step 5: open the node, keep for HIDIOC[GS]FEATURE ioctls.
        Err(HidError::custom("open_feature_handle: not yet implemented on FreeBSD"))
    }
}

impl AsyncHidRead for HidDevice {
    fn read_input_report<'a>(
        &'a mut self,
        _buf: &'a mut [u8],
    ) -> impl Future<Output = HidResult<usize>> + Send + 'a {
        // Step 3: async read on the wrapped fd.
        async { Err(HidError::custom("read_input_report: not yet implemented on FreeBSD")) }
    }
}

impl AsyncHidWrite for HidDevice {
    fn write_output_report<'a>(
        &'a mut self,
        _buf: &'a [u8],
    ) -> impl Future<Output = HidResult<()>> + Send + 'a {
        // Step 4: async write on the wrapped fd.
        async { Err(HidError::custom("write_output_report: not yet implemented on FreeBSD")) }
    }
}

impl AsyncHidFeatureHandle for HidDevice {
    fn read_feature_report<'a>(
        &'a mut self,
        _buf: &'a mut [u8],
    ) -> impl Future<Output = HidResult<usize>> + Send + 'a {
        // Step 5: HIDIOCGFEATURE ioctl. First byte of buf is the report id
        // (0 for unnumbered devices), report data returned starting at byte 0.
        async { Err(HidError::custom("read_feature_report: not yet implemented on FreeBSD")) }
    }

    fn write_feature_report<'a>(
        &'a mut self,
        _buf: &'a [u8],
    ) -> impl Future<Output = HidResult<()>> + Send + 'a {
        // Step 5: HIDIOCSFEATURE ioctl. First byte of buf is the report id;
        // report data starts at byte 1 for numbered devices, byte 0 otherwise.
        async { Err(HidError::custom("write_feature_report: not yet implemented on FreeBSD")) }
    }
}
