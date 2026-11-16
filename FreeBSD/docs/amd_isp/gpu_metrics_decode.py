#!/usr/bin/env python3
# Decode an amdgpu gpu_metrics v3.0 table (Strix Halo, SMU 14.0.x).
# FreeBSD: sysctl -b hw.amdisp.gpu_metrics > f
# Linux:   cat /sys/class/drm/card1/device/gpu_metrics > f
# Usage: gpu_metrics_decode.py f [f2]  (two files print side by side)
# Offsets from offsetof() on struct gpu_metrics_v3_0 (kgd_pp_interface.h).
import struct, sys
SIZE = {'uint8_t': 'B', 'uint16_t': 'H', 'uint32_t': 'I', 'uint64_t': 'Q'}
FIELDS = [
    ("temperature_gfx", 4, 1, "uint16_t"),
    ("temperature_soc", 6, 1, "uint16_t"),
    ("temperature_core", 8, 16, "uint16_t"),
    ("temperature_skin", 40, 1, "uint16_t"),
    ("average_gfx_activity", 42, 1, "uint16_t"),
    ("average_vcn_activity", 44, 1, "uint16_t"),
    ("average_ipu_activity", 46, 8, "uint16_t"),
    ("average_core_c0_activity", 62, 16, "uint16_t"),
    ("average_dram_reads", 94, 1, "uint16_t"),
    ("average_dram_writes", 96, 1, "uint16_t"),
    ("average_ipu_reads", 98, 1, "uint16_t"),
    ("average_ipu_writes", 100, 1, "uint16_t"),
    ("system_clock_counter", 104, 1, "uint64_t"),
    ("average_socket_power", 112, 1, "uint32_t"),
    ("average_ipu_power", 116, 1, "uint16_t"),
    ("average_apu_power", 120, 1, "uint32_t"),
    ("average_gfx_power", 124, 1, "uint32_t"),
    ("average_dgpu_power", 128, 1, "uint32_t"),
    ("average_all_core_power", 132, 1, "uint32_t"),
    ("average_core_power", 136, 16, "uint16_t"),
    ("average_sys_power", 168, 1, "uint16_t"),
    ("stapm_power_limit", 170, 1, "uint16_t"),
    ("current_stapm_power_limit", 172, 1, "uint16_t"),
    ("average_gfxclk_frequency", 174, 1, "uint16_t"),
    ("average_socclk_frequency", 176, 1, "uint16_t"),
    ("average_vpeclk_frequency", 178, 1, "uint16_t"),
    ("average_ipuclk_frequency", 180, 1, "uint16_t"),
    ("average_fclk_frequency", 182, 1, "uint16_t"),
    ("average_vclk_frequency", 184, 1, "uint16_t"),
    ("average_uclk_frequency", 186, 1, "uint16_t"),
    ("average_mpipu_frequency", 188, 1, "uint16_t"),
    ("current_coreclk", 190, 16, "uint16_t"),
    ("current_core_maxfreq", 222, 1, "uint16_t"),
    ("current_gfx_maxfreq", 224, 1, "uint16_t"),
    ("throttle_residency_prochot", 228, 1, "uint32_t"),
    ("throttle_residency_spl", 232, 1, "uint32_t"),
    ("throttle_residency_fppt", 236, 1, "uint32_t"),
    ("throttle_residency_sppt", 240, 1, "uint32_t"),
    ("throttle_residency_thm_core", 244, 1, "uint32_t"),
    ("throttle_residency_thm_gfx", 248, 1, "uint32_t"),
    ("throttle_residency_thm_soc", 252, 1, "uint32_t"),
    ("time_filter_alphavalue", 256, 1, "uint32_t"),
]

def decode(path):
    b = open(path, 'rb').read()
    size, frev, crev = struct.unpack_from('<HBB', b, 0)
    if (frev, crev) != (3, 0):
        sys.exit(f'{path}: format {frev}.{crev}, expected 3.0')
    out = {}
    for name, off, count, typ in FIELDS:
        v = struct.unpack_from('<%d%s' % (count, SIZE[typ]), b, off)
        out[name] = v[0] if count == 1 else ' '.join(map(str, v))
    return out

tables = [decode(p) for p in sys.argv[1:]]
for name, *_ in FIELDS:
    print('%-32s' % name, *('%-24s' % t[name] for t in tables))
