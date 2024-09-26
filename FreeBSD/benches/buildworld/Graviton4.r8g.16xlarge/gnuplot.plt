# Gnuplot script file for plotting data from bench lab

set yrange [0:*]
set decimalsign locale
set terminal png truecolor size 1920,1080 font "Gill Sans,22"
set output 'graph.png'
set grid back
set border 3 back linestyle 80
set tics nomirror
set style fill solid 1.0 border -1
set style histogram errorbars gap 2 lw 2
set boxwidth 0.9 relative

set title noenhanced "Job numbers' impact on 'make TARGET_ARCH=riscv64 buildworld' execution time\nARM Neoverse-V2 r0p1 (cores: 64, thread per core: 1, Total CPUs: 64) with 503 GB RAM\n src and obj on tmpfs"
set xlabel font "Gill Sans,16"
set xlabel noenhanced "FreeBSD/arm64 15.0-CURRENT (1500023) building main sources cloned at d2c2d5f49 (2024-09-25 19:14:36 +0200)"
set ylabel "Time to build in seconds, median of 3 benches"

set xtics 1
set key on inside top right
plot "gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram notitle,   ''using 0:( $2 + 80 ):2 with labels notitle