#!/usr/bin/perl -l

#executes a command
#params:
#   $cmd - scalar - the command to execute
#   $_[1] - scalar - return parameter for command output
#return scalar, the exit status of the command
sub cmd {
   my ($cmd) = @_;

   $_[1] = `$cmd`;

   $?;
}

1;
