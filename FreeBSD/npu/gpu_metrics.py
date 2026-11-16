#!/usr/bin/env python3
"""Decode amdgpu gpu_metrics v3.0 (SMU 14, Strix Point/Halo) power fields.

Usage: gpu_metrics.py [FILE]   (default: the first amdgpu card's
/sys/class/drm/card*/device/gpu_metrics; "-" reads stdin, e.g. from
"sysctl -b sys.device.drmn0.gpu_metrics" on FreeBSD)

Layout: struct gpu_metrics_v3_0, drivers/gpu/drm/amd/include/
kgd_pp_interface.h.  Powers are SMU time-filtered averages in mW.
"""
import ctypes as C
import glob
import sys

u16, u32, u64 = C.c_uint16, C.c_uint32, C.c_uint64


class GpuMetricsV3(C.Structure):
    _fields_ = [
        ("structure_size", u16), ("format_revision", C.c_uint8),
        ("content_revision", C.c_uint8),
        ("temperature_gfx", u16), ("temperature_soc", u16),
        ("temperature_core", u16 * 16), ("temperature_skin", u16),
        ("average_gfx_activity", u16), ("average_vcn_activity", u16),
        ("average_ipu_activity", u16 * 8),
        ("average_core_c0_activity", u16 * 16),
        ("average_dram_reads", u16), ("average_dram_writes", u16),
        ("average_ipu_reads", u16), ("average_ipu_writes", u16),
        ("system_clock_counter", u64),
        ("average_socket_power", u32), ("average_ipu_power", u16),
        ("average_apu_power", u32), ("average_gfx_power", u32),
        ("average_dgpu_power", u32), ("average_all_core_power", u32),
        ("average_core_power", u16 * 16), ("average_sys_power", u16),
        ("stapm_power_limit", u16), ("current_stapm_power_limit", u16),
        ("average_gfxclk_frequency", u16), ("average_socclk_frequency", u16),
        ("average_vpeclk_frequency", u16), ("average_ipuclk_frequency", u16),
        ("average_fclk_frequency", u16), ("average_vclk_frequency", u16),
        ("average_uclk_frequency", u16), ("average_mpipu_frequency", u16),
        ("current_coreclk", u16 * 16), ("current_core_maxfreq", u16),
        ("current_gfx_maxfreq", u16),
        ("throttle_residency_prochot", u32), ("throttle_residency_spl", u32),
        ("throttle_residency_fppt", u32), ("throttle_residency_sppt", u32),
        ("throttle_residency_thm_core", u32),
        ("throttle_residency_thm_gfx", u32),
        ("throttle_residency_thm_soc", u32),
        ("time_filter_alphavalue", u32),
    ]


FIELDS = ("average_socket_power", "average_apu_power", "average_ipu_power",
          "average_gfx_power", "average_all_core_power",
          "average_dram_reads", "average_ipu_reads")


def path():
    for p in sorted(glob.glob("/sys/class/drm/card*/device/gpu_metrics")):
        return p
    sys.exit("no gpu_metrics")


def sysctl_raw(name="sys.device.drmn0.gpu_metrics"):
    """FreeBSD: read a binary sysctl without forking sysctl(8)."""
    libc = C.CDLL(None, use_errno=True)
    size = C.c_size_t(4096)
    buf = C.create_string_buffer(size.value)
    if libc.sysctlbyname(name.encode(), buf, C.byref(size), None, 0) != 0:
        raise OSError(C.get_errno(), f"sysctlbyname {name}")
    return buf.raw[:size.value]


def read(p=None):
    return decode(sys.stdin.buffer.read() if p == "-" else
                  open(p or path(), "rb").read())


def decode(raw):
    if len(raw) < C.sizeof(GpuMetricsV3):
        raise ValueError(f"gpu_metrics is {len(raw)} bytes")
    m = GpuMetricsV3.from_buffer_copy(raw[:C.sizeof(GpuMetricsV3)])
    if (m.format_revision, m.content_revision) != (3, 0):
        raise ValueError(f"gpu_metrics v{m.format_revision}."
                         f"{m.content_revision}, expected v3.0")
    return {f: getattr(m, f) for f in FIELDS}


def decode_all(raw):
    """Every field; arrays become lists."""
    m = GpuMetricsV3.from_buffer_copy(raw[:C.sizeof(GpuMetricsV3)])
    out = {}
    for name, _ in GpuMetricsV3._fields_:
        v = getattr(m, name)
        out[name] = list(v) if isinstance(v, C.Array) else v
    return out


if __name__ == "__main__":
    for k, v in read(sys.argv[1] if len(sys.argv) > 1 else None).items():
        print(f"{k:24s} {v}")
