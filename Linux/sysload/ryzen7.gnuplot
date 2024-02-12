set title "Comparing reported PPT by a Ryzen7 vs Measured Watt during Phrononix benches"
set datafile separator ',' # csv file format
set xdata time # Using the first column as x axis date time
set timefmt "%s" #  specify our time string format (Epoch here)
# set xtics 3600
set format x "%H:%M:%S" # otherwise it will show only MM:SS
set key autotitle columnhead # use the first line as title
set ylabel "Percentage" # label for the Y axis
set yrange [0:100] # Using smooth could generate more than 2100 result
set xlabel 'Time' # label for the X axis
set y2tics # enable second axis
set ytics nomirror # dont show the tics on that side
set y2label "Watt" # label for second axis
set y2range [0:] # force axist starting at 0

# style
set style line 100 lt 1 lc rgb "grey" lw 0.5 # linestyle for the grid
set grid ls 100 # enable grid with specific linestyle
#set ytics 1 # smaller ytics
#set xtics 1   # smaller xtics
set style line 101 lw 3 lt rgb "red"
set style line 102 lw 3 lt rgb "orange"
set style line 103 lw 2 lt rgb "blue"
set style line 104 lw 2 lt rgb "cyan"

# Output
set terminal pngcairo size 1024,768 enhanced font 'Segoe UI,10'
set output 'ryzen7-PPTvsShelly.png'
#
# plot
plot "<xzcat ryzen7.csv.xz" using 1:2 smooth acspline with lines ls 103, '' using 1:11 smooth acspline with lines ls 104, \
	'' using 1:9 smooth acspline with lines axis x1y2 ls 102, '' using 1:18 smooth acspline with lines axis x1y2 ls 101
