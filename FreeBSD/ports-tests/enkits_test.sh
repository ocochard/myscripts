#!/bin/sh
# enkits smoke test: install the freshly built package, build & run two tiny
# programs against the library (C interface + C++ interface), and exercise the
# installed CMake package config via find_package(enkiTS).
set -eu

PORT_NAME=enkits
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-test.XXXXXX)

cleanup() {
	rm -rf "${WORKDIR}"
	sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 1. Install fresh package
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
sudo pkg add -f "${PKG}"

# 2. Files landed where the port claims
for f in \
	/usr/local/include/enkiTS/TaskScheduler.h \
	/usr/local/include/enkiTS/TaskScheduler_c.h \
	/usr/local/lib/libenkiTS.so \
	/usr/local/lib/cmake/enkiTS/enkiTSConfig.cmake
do
	test -e "${f}" || { echo "missing: ${f}"; exit 1; }
done

# 3. C-interface smoke: parallel task set increments an atomic counter, then
# verify the final count matches the set size.
cat > "${WORKDIR}/c_smoke.c" <<'EOF'
#include <enkiTS/TaskScheduler_c.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static atomic_uint counter;

static void run(uint32_t start, uint32_t end, uint32_t thread, void* args) {
	(void)thread; (void)args;
	for (uint32_t i = start; i < end; ++i)
		atomic_fetch_add(&counter, 1u);
}

int main(void) {
	enkiTaskScheduler* ets = enkiNewTaskScheduler();
	enkiInitTaskScheduler(ets);
	enkiTaskSet* task = enkiCreateTaskSet(ets, run);
	const uint32_t N = 100000;
	enkiAddTaskSetArgs(ets, task, NULL, N);
	enkiWaitForTaskSet(ets, task);
	enkiDeleteTaskSet(ets, task);
	enkiWaitforAllAndShutdown(ets);
	enkiDeleteTaskScheduler(ets);
	unsigned final = atomic_load(&counter);
	printf("c_smoke counter=%u expected=%u threads=%u\n",
	    final, N, 0u);
	return final == N ? 0 : 1;
}
EOF

cc -O2 -I/usr/local/include -L/usr/local/lib \
	-o "${WORKDIR}/c_smoke" "${WORKDIR}/c_smoke.c" -lenkiTS -lpthread
"${WORKDIR}/c_smoke" | tee "${WORKDIR}/c_smoke.out"
grep -q "c_smoke counter=100000 expected=100000" "${WORKDIR}/c_smoke.out"

# 4. C++ interface smoke: TaskSet subclass with parallel reduction.
cat > "${WORKDIR}/cxx_smoke.cpp" <<'EOF'
#include <enkiTS/TaskScheduler.h>
#include <atomic>
#include <cstdio>

static std::atomic<uint64_t> sum{0};

struct AddRange : enki::ITaskSet {
	void ExecuteRange(enki::TaskSetPartition r, uint32_t) override {
		uint64_t local = 0;
		for (uint32_t i = r.start; i < r.end; ++i) local += i;
		sum.fetch_add(local, std::memory_order_relaxed);
	}
};

int main() {
	enki::TaskScheduler ts;
	ts.Initialize();
	AddRange task;
	const uint32_t N = 100000;
	task.m_SetSize = N;
	ts.AddTaskSetToPipe(&task);
	ts.WaitforTask(&task);
	ts.WaitforAllAndShutdown();
	const uint64_t expected = (uint64_t)(N - 1) * N / 2;
	std::printf("cxx_smoke sum=%llu expected=%llu\n",
	    (unsigned long long)sum.load(),
	    (unsigned long long)expected);
	return sum.load() == expected ? 0 : 1;
}
EOF

c++ -O2 -std=c++11 -I/usr/local/include -L/usr/local/lib \
	-o "${WORKDIR}/cxx_smoke" "${WORKDIR}/cxx_smoke.cpp" -lenkiTS -lpthread
"${WORKDIR}/cxx_smoke" | tee "${WORKDIR}/cxx_smoke.out"
grep -q "cxx_smoke sum=4999950000 expected=4999950000" "${WORKDIR}/cxx_smoke.out"

# 5. CMake package config: find_package(enkiTS) must succeed and the imported
# target enkiTS::enkiTS must propagate include dirs + link the shared lib.
# Note: upstream sets INTERFACE_INCLUDE_DIRECTORIES to .../include/enkiTS, so
# CMake consumers include "TaskScheduler.h" directly (no enkiTS/ subdir).
mkdir -p "${WORKDIR}/cmake-test"
cat > "${WORKDIR}/cmake-test/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(enkits_smoke CXX)
find_package(enkiTS CONFIG REQUIRED)
add_executable(smoke smoke.cpp)
target_link_libraries(smoke PRIVATE enkiTS::enkiTS)
EOF
cat > "${WORKDIR}/cmake-test/smoke.cpp" <<'EOF'
#include "TaskScheduler.h"
#include <atomic>
#include <cstdio>

static std::atomic<uint64_t> sum{0};

struct AddRange : enki::ITaskSet {
	void ExecuteRange(enki::TaskSetPartition r, uint32_t) override {
		uint64_t local = 0;
		for (uint32_t i = r.start; i < r.end; ++i) local += i;
		sum.fetch_add(local, std::memory_order_relaxed);
	}
};

int main() {
	enki::TaskScheduler ts;
	ts.Initialize();
	AddRange task;
	const uint32_t N = 100000;
	task.m_SetSize = N;
	ts.AddTaskSetToPipe(&task);
	ts.WaitforTask(&task);
	ts.WaitforAllAndShutdown();
	const uint64_t expected = (uint64_t)(N - 1) * N / 2;
	std::printf("cmake_smoke sum=%llu expected=%llu\n",
	    (unsigned long long)sum.load(),
	    (unsigned long long)expected);
	return sum.load() == expected ? 0 : 1;
}
EOF
cmake -S "${WORKDIR}/cmake-test" -B "${WORKDIR}/cmake-test/build" \
	-DCMAKE_PREFIX_PATH=/usr/local >/dev/null
cmake --build "${WORKDIR}/cmake-test/build" >/dev/null
"${WORKDIR}/cmake-test/build/smoke" | grep -q "cmake_smoke sum=4999950000 expected=4999950000"

echo "PASS  ${PORT_NAME}"
