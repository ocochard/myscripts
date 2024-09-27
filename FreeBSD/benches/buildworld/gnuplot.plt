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

set title noenhanced "Job numbers' impact on 'make TARGET_ARCH=riscv64 buildworld' execution time\n src and obj on tmpfs"
set xlabel font "Gill Sans,16"
set xlabel noenhanced "FreeBSD/arm64 15.0-CURRENT (1500023) building main sources cloned at d2c2d5f49 (2024-09-25 19:14:36 +0200)
set ylabel "Time to build in seconds, median of 3 benches"

# dx = 1/(2 * (numberOfTorres + gap))
dx = 1/12.0

set xtics 1
set key on inside top right
plot  "<head -5 Ampere.Altra.Mt.Collins/gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram title "Ampere Altra Mt. Collins (2 packages, 80 cores = 160 cores)",   ''using 0:( $2 + 10 ):2 with labels offset -7,0.5 notitle, \
  "AMD.Epyc.7502P/gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram title "AMD EPYC 7502P (1 package, 32 cores = 64 threads)",   ''using 0:( $2 + 10 ):2 with labels offset -4,-2 notitle, \
  "m5d.metal/gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram title "AWS m5d.metal, Intel Xeon 8259CL (2 packages, 24 cores, 2 hw threads = 96 threads)",   ''using 0:( $2 + 10 ):2 with labels offset -2,2 notitle, \
  "Graviton2.c6gd.16xlarge/gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram title "AWS Graviton 2 c6gd.16xlarge (1 package, 64 cores)",   ''using 0:( $2 + 10 ):2 with labels offset 2,1.5 notitle, \
  "Graviton3.c7gd.16xlarge/gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram title "AWS Graviton 3 c7gd.16xlarge (1 package, 64 cores)",   ''using 0:( $2 + 10 ):2 with labels offset 5,1 notitle, \
"Graviton4.r8g.16xlarge/gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram title "AWS Graviton 4 r8g.16xlarge (1 package, 64 cores)",   ''using 0:( $2 + 10 ):2 with labels offset 7,0.5 notitle

