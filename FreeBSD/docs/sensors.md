what the current status of sensors framwork (to collect and present in a normalized way: cpu package power consumption, battery status, fan speed, etc.) on different OS: Linux, FreeBSD, NetBSD, OpenBSD, etc.


Hardware telemetry handling varies significantly across operating systems. While some kernels offer a single, deeply unified framework for *all* environmental monitoring, others separate platform devices (like fans and desktop sensors) from power subsystems (like laptops batteries).

---

## 1. Linux: The `hwmon` & `power_supply` Subsystems

Linux approaches sensor normalization using two distinct, mature driver subsystems. They do not share the exact same internal framework but are completely normalized via **`sysfs`** attributes (`/sys/class/...`), allowing userspace tools to treat them uniformly.

* **CPU Power / Fans / Voltages:** Managed by the **`hwmon`** (Hardware Monitoring) subsystem.
* *Normalization:* Data is exported under `/sys/class/hwmon/hwmonX/`. Standardized file naming conventions handle the sorting (e.g., `temp1_input` for micro-degrees Celsius, `fan1_input` for RPM, `power1_input` for micro-Watts).
* *CPU Package Power:* Polled via drivers like `intel_rapl` or `amd_energy`, which plug straight into `hwmon` or powercap.


* **Battery Status / AC Power:** Separated out into the **`power_supply`** subsystem.
* *Normalization:* Exported under `/sys/class/power_supply/BATX/` with normalized attributes like `capacity`, `voltage_now`, and `status` (Charging/Discharging).


* **Current Status:** Highly active. Maintained heavily by both corporate vendor patches and independent developers, expanding rapidly to cover Apple Silicon (`macsmc-hwmon`), modern AMD/Intel platform controllers, and specialized desktop controller modules.

---

## 2. OpenBSD: The `hw.sensors` Framework

OpenBSD boasts one of the most elegantly unified and strictly normalized frameworks across any OS. It explicitly treats *everything*—temperatures, fans, voltages, power usage, and battery state—as a single data type: a **sensor**.

* **The Framework:** A unified subsystem exposed to userspace via the `sysctl` tree under **`hw.sensors`**.
* **Normalization:** Every driver translates raw hardware registers into a standardized `struct ksensor`. The kernel enforces unified sensor types (e.g., `SENSOR_TEMP` in Kelvins, `SENSOR_FANRPM`, `SENSOR_VOLTS`, `SENSOR_WATTS`, and `SENSOR_PERCENT` / `SENSOR_INDICATOR` for batteries).
* **Unified Presentation:** Because the framework forces all telemetry into the same pipeline, tools like the native `sysctl hw.sensors` command or the **`sensorsd(8)`** monitoring daemon track fans, temperatures, and battery percentages side-by-side using the same API rules.
* **Current Status:** Rock-solid and widely supported. OpenBSD continually expands `hw.sensors` bindings for new IPMI systems, modern AMD/Intel internal drivers, and I2C/SMBus controller chips.

---

## 3. NetBSD: The `envsys` Framework

NetBSD uses a highly structured, unified platform called **`envsys`** (Environmental Systems Monitor). Similar to OpenBSD, it was designed to keep disparate drivers from inventing their own telemetry formats.

* **The Framework:** Drivers export data using the **ENVSYS API**. Userspace interacts with the framework via `/dev/sysmon` using ioctl calls, or via the **`envstat(8)`** utility.
* **Normalization:** `envsys` handles normalized property lists (using XML-like `prop_dictionary`). It classifies sensors strictly by type: `ENVSYS_STEMP` (Celsius), `ENVSYS_SFANRPM`, `ENVSYS_SVOLTS`, `ENVSYS_BATTERY_CAPACITY`, and `ENVSYS_BATTERY_CHARGE`.
* **Current Status:** Very stable and highly integrated. In the latest releases (such as NetBSD 11), `envsys` fully unifies x86 ACPI/thermal inputs, power profiles, and hardware components natively. It features explicit configuration via `/etc/envsys.conf` to handle system-wide thresholds and actions (e.g., automated shutdown if a thermal or battery state trips a critical limit).

---

## 4. FreeBSD: Hybrid `sysctl` Nodes

Unlike its sister BSDs, FreeBSD does not feature a single, overarching "Sensors Subsystem" kernel abstraction code layer. Instead, it relies heavily on individual drivers populating organized hierarchies within the global **`sysctl` MIB tree**.

* **CPU Power / Temperatures:** Normalized mostly via the **`dev.cpu`** and ACPI hierarchies.
* *CPU Temperature:* The `coretemp(4)` (Intel) and `amdtemp(4)` drivers populate nodes like `dev.cpu.X.temperature`.
* *CPU Package Power:* Exposed via the `cpuctl(4)` driver and specific performance counters (MSRs), rather than a centralized sensor grid.


* **Fans & Desktop Hardwares:** Populated via ACPI (`hw.acpi.thermal`) or standalone drivers (like `aichips(4)` or IPMI framework bindings) resulting in varying sysctl paths depending on the exact hardware build.
* **Battery Status:** Handled strictly through ACPI power management nodes located under `hw.acpi.battery`.
* **Current Status:** Functional, though less cohesive for developers writing universal monitoring agents. While userspace applications (like `sysutils/lm_sensors` ports or custom tools like `monbsd`) must crawl completely different `sysctl` trees depending on what they are measuring, FreeBSD's driver support for modern laptop chipsets and server management (IPMI) remains deep and highly reliable.

---

## Summary Matrix

| Operating System | Central Framework Name | Userspace Access Method | Degree of Battery/Thermal Unification |
| --- | --- | --- | --- |
| **Linux** | `hwmon` & `power_supply` | `/sys/class/hwmon/` & `/sys/class/power_supply/` | **Split** (Platform components vs. Power sources) |
| **OpenBSD** | `hw.sensors` | `sysctl hw.sensors` / `sensorsd` | **Fully Unified** (Everything is an indexed `ksensor`) |
| **NetBSD** | `envsys` | `envstat` / `/dev/sysmon` | **Fully Unified** (Managed through `sysmon_envsys`) |
| **FreeBSD** | *None* (Driver-level `sysctl`) | `sysctl dev.cpu` / `sysctl hw.acpi` | **Fragmented** (Relies entirely on strict `sysctl` naming conventions) |

Are you writing a cross-platform monitoring tool, or are you trying to surface specific hardware metrics on one of these systems right now?

I’m looking on improving the FreeBSD support for sensors, so I am collecting all existing solution to look for the best one

Improving FreeBSD’s hardware telemetry is a fantastic goal. The current state of FreeBSD sensor reporting is fragmented, forcing developers of monitoring agents (like `telegraf`, `prometheus-node-exporter`, or `conky`) to write fragile code that crawls a dozen completely unrelated `sysctl` MIB branches.

If you are evaluating frameworks to build a cleaner, unified solution for FreeBSD, comparing the architectures of the other operating systems yields valuable insights.

---

## The Core Deficiencies in FreeBSD's Current Model

Currently, FreeBSD relies entirely on driver-level `sysctl` population without a central middle layer:

* **CPU Temperatures:** `dev.cpu.<N>.temperature` (populated by `coretemp` or `amdtemp`).
* **Motherboard/Chassis Fans & Volts:** Handled by standalone drivers like `aichips(4)`, `ipmi(4)`, or ACPI (`hw.acpi.thermal`), creating chaotic sysctl structures depending on the motherboard manufacturer.
* **Batteries:** Completely separate under `hw.acpi.battery`.
* **CPU Energy/Power Consumption:** Often unexposed directly as a clean sensor metric, requiring digging into performance counters or MSRs via `cpuctl(4)`.

---

## Evaluating the Options for FreeBSD

To implement a unified framework, you essentially have three major structural blueprints you can follow.

### Approach 1: The OpenBSD `hw.sensors` Blueprint (The Cleanest Architecture)

OpenBSD's model is arguably the gold standard for micro-architectural design in BSD.

* **How it works:** The kernel provides a standardized API (`sysmon`). Drivers register individual sensors using a strictly defined `struct ksensor`. The kernel framework handles all normalization.
* **Why it fits FreeBSD:** It allows you to build a single, centralized MIB (e.g., `hw.sensors`) in FreeBSD. Whether a driver reads a battery percentage via ACPI, an RPM speed from an IPMI bus, or a watt draw from an AMD CPU, it simply registers to the framework.
* **Pros:** Highly uniform userspace API. Programs only ever have to parse one `sysctl` tree.
* **Cons:** Requires a massive internal API overhaul and getting subsystem maintainers to rewrite driver attach functions to use the new registration API.

### Approach 2: The Linux `hwmon` / `sysfs` Blueprint (The Virtual File System Model)

Linux splits sensors by class type using virtual files in `/sys/class/hwmon/`.

* **How it works:** Instead of relying on a system call or a MIB tree structure, Linux exposes text files using a strict naming convention (e.g., `temp1_input`).
* **Why it fits FreeBSD:** FreeBSD already has `linsysfs` (a Linux-compatible sysfs layer used for the Linux compatibility framework).
* **Pros:** It makes porting Linux monitoring software flawlessly easy.
* **Cons:** It goes entirely against the "BSD way." FreeBSD developers generally prefer `sysctl` for system metrics rather than pseudo-filesystems. Implementing a heavy VFS structure just for sensors would likely face massive pushback from the FreeBSD Core Team.

### Approach 3: The NetBSD `envsys` Blueprint (The Object/Property List Model)

NetBSD passes telemetry data between the kernel and userspace using structured XML-like property lists (`prop_dictionary`).

* **How it works:** Userspace communicates with a central `/dev/sysmon` device node using `ioctl` calls.
* **Pros:** Highly extensible. It allows you to easily attach metadata to a sensor (e.g., "Critical Threshold High", "Sensor Description").
* **Cons:** Overly complex. Parsing serialized property lists or raw ioctl blocks creates higher overhead and friction for simple userspace scripting compared to a clean `sysctl` structure.

---

## Architectural Recommendation for FreeBSD

If your goal is to design a framework that the FreeBSD community will actually merge into the base system, **the OpenBSD `hw.sensors` approach adapted to a clean `sysctl` tree is your best path.**

Instead of creating a brand-new API from scratch, you can look at the historical `sysmon` framework or design a **Unified Hardware Sensor Interface Layer** that sits right beneath `sysctl`.

```
+--------------------------------------------------------------+
|                        USERSPACE                             |
|        (sysctl hw.sensors / Prometheus / telegraf / top)      |
+--------------------------------------------------------------+
                               |
                               v
+--------------------------------------------------------------+
|                     FREEBSD KERNEL CORE                      |
|                  sysctl MIB: `hw.sensors`                    |
+--------------------------------------------------------------+
                               |
            (Unified Sensor Registration API)
                               |
+--------------------------------------------------------------+
|                       DRIVER LAYER                           |
|  [coretemp(4)]   [acpi_battery(4)]   [ipmi(4)]   [amdtemp(4)]|
+--------------------------------------------------------------+

```

### Proposed Structure for a Native FreeBSD Implementation

You could propose a new `sysctl` top-level or mid-level node (`hw.sensors`) that acts as an aggregator. When drivers load, they use a kernel function like `sensor_attach()` to inject data into this tree.

```text
hw.sensors.cpu0.temp0: 42.0C
hw.sensors.cpu0.power0: 15.4W   <-- Normalizes Intel RAPL / AMD Energy
hw.sensors.acpi0.bat0.capacity: 88%
hw.sensors.ipmi0.fan1: 2400RPM

```

By enforcing standard units inside the kernel structure (e.g., millicelsius, milliwatts, RPM) before presenting them to the `sysctl` node, you immediately eliminate the fragmented logic that plagues monitoring software on FreeBSD today.

Where are you planning to start your implementation—are you looking to write a wrapper kernel module to test the waters, or are you aiming straight for a base system architectural change?
