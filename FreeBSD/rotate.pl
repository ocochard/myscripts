#! /usr/bin/env -S perl
use 5.012;      # implies "use strict;"
use warnings FATAL => 'all'; # make warnings throw exceptions
use autodie;    # open() and others die on error
use English;    # allows to use $PROCESS_ID or $PID in place of $$, $ARG in place of $_
                # https://perldoc.perl.org/perlvar
use File::Copy;

# Subroutine prototype
sub logrotate ($$);

# MAIN

# example
logrotate('/var/log/update.log',6);


# Subroutine definition

sub logrotate($$)
{
	my $file = shift;
	my $max = shift;
	if ( -e $file.$max) {
		unlink("$file.$max");
	}
	my $i = $max - 1;
	while ($i >= 0) {
		if ( -e "${file}.${i}") {
			my $src = $file . '.' . ${i};
			my $dst = $file . '.' . ($i + 1);
			move($src,$dst);
		}
		$i--;
	}
	if ( -e $file) {
		move(${file},$file . '.0');
	}
}
