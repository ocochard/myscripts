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

# Line styles: try to pick pleasing colors, rather
# # than strictly primary colors or hard-to-see colors
# # like gnuplot's default yellow.  Make the lines thick
# # so they're easy to see in small plots in papers.
set style line 1 lt 1
set style line 2 lt 1
set style line 3 lt 1
set style line 4 lt 1
set style line 5 lt 1
set style line 6 lt 1
set style line 1 lt rgb "#A00000" lw 2 pt 7
set style line 2 lt rgb "#00A000" lw 2 pt 9
set style line 3 lt rgb "#5060D0" lw 2 pt 5
set style line 4 lt rgb "#F25900" lw 2 pt 13
set style line 5 lt rgb '#8b1a0e' lw 2 pt 1 # red
set style line 6 lt rgb '#5e9c36' lw 2 pt 6 # green

set xtics 1
set key on inside top right
plot "< head -n 5 Ampere.Altra.Mt.Collins/gnuplot.real.data" using 1:2:xtic(1) title 'Ampere Altra Mt. Collins (2 packagesx 80 cores = 160 cores)' with linespoints ls 5, \
     "" using 1:2:3:4 with yerrorbars ls 5 notitle, \
	 "AMD.Epyc.7502P/gnuplot.real.data" using 1:2:xtic(1) title 'AMD EPYC 7502P (32 cores x 2 threads = 64 threads' with linespoints ls 2, \
     "" using 1:2:3:4 with yerrorbars notitle ls 2, \
	 "c6a.16xlarge/gnuplot.real.data" using 1:2:xtic(1) title 'AWS c6a.16xlarge, AMD EPYC 7R13 Processor (32 cores x 2 threads = 64 threads)' with linespoints ls 3, \
     "" using 1:2:3:4 with yerrorbars ls 3 notitle, \
	 "< head -n 5 c6a.metal/gnuplot.real.data" using 1:2:xtic(1) title 'AWS c6a.metal, AMD EPYC 7R13 Processor (96 cores x 2 threads = 192 threads)' with linespoints ls 4, \
     "" using 1:2:3:4 with yerrorbars ls 4 notitle, \
	 "m5d.metal/gnuplot.real.data" using 1:2:xtic(1) title 'AWS m5d.metal, Intel Xeon 8259CL (2 packages x 24 cores x 2 threads = 96 threads)' with linespoints ls 1, \
     "" using 1:2:3:4 with yerrorbars ls 1 notitle, \
	"Graviton2.c6gd.16xlarge/gnuplot.real.data" using 1:2:xtic(1) title 'AWS Graviton 2 c6gd.16xlarge (64 cores)' with linespoints, \
     "" using 1:2:3:4 with yerrorbars notitle,\
	"Graviton3.c7gd.16xlarge/gnuplot.real.data" using 1:2:xtic(1) title 'AWS Graviton 3 c7gd.16xlarge (64 cores)' with linespoints, \
     "" using 1:2:3:4 with yerrorbars notitle,\
	"Graviton4.r8g.16xlarge/gnuplot.real.data" using 1:2:xtic(1) title 'AWS Graviton 4 r8g.16xlarge (64 cores)' with linespoints ls 6 , \
     "" using 1:2:3:4 with yerrorbars ls 6 notitle,
