#!/usr/bin/perl -l

require 'funcs.pl'; #cmd subroutine

use Data::Dumper; #for debugging purposes
use POSIX ':sys_wait_h';

$| = 1; #flush output

#Configurable daemon class to manage multiple multi-process jobs
#see README.md for detailed description of features and sample usage.
package Daemon;

use strict; #force lexical scoping

#constructor
#params:
#   $params - hash reference - settings to use for the daemon
#return blessed Daemon object (hash)
sub new {
   my ($class, $params) = @_;

   my $self = {};
 
   $self->{'jobs'} = $params->{'jobs'} || [];
   $self->{'children'} = [];
   
   $self->{'started'} = 0;
   $self->{'stopped'} = 0;

   $self->{'is_child'} = 0;

   $self->{'kill_attempts'} = $params->{'kill_attempts'} || 5;

   $self->{'revive_children'} = defined $params->{'revive_children'}?$params->{'revive_children'}:1;

   $self->{'repeat_children'} = defined $params->{'repeat_children'}?$params->{'repeat_children'}:1;

   $self->{'miss_count'} = 0;

   $self->{'sleep_interval'} = $params->{'sleep_interval'} || 60;

   $self->{'stop_force_time'} = $params->{'stop_force_time'} || 10;

   $self->{'exit_callback'} = $params->{'exit_callback'} || undef;

   $self->{'force_stop'} = 0;

   $self = bless $self, $class;

   $self->init_sig_handlers();

   $self;
}

#initializes the signal handlers used by the daemon
#return 1
sub init_sig_handlers {
   my $self = shift();

   my $HUP = sub {
      $self->log('SIGHUP received');

      return 0 if $self->{'is_child'};

      if($self->{'started'} && !$self->{'stopped'}){
         $self->log('restarting');
       
         my $callback = sub {
            $self->log('all child processes stopped, starting again...');
            $self->log('failed to restart') unless $self->start() || $self->is_started;
         };

         unless($self->stop(0, $callback) || $self->stopped){
            $self->log('failed to stop, will not restart');
         }
      }else{
         $self->log('nothing to do');
      }
   
   };

   my $CHLD = sub {
      $self->log('SIGCHLD received');

      return 0 if $self->{'is_child'};

      my $child_pid = waitpid -1, ::WNOHANG;
      my $exit_status = $?;

      return 0 if $self->{'force_stop'};

      if($child_pid == -1){
         $self->log('an error occurred handling SIGCHLD');
         return 0;
      }

      unless($child_pid){
         $self->log('no child is available');
         return 0;
      }

      $self->log('child with pid ' . $child_pid . ' exitted with status ' . $exit_status);

      my $old_child = $self->remove_child($child_pid);

      if($self->{'revive_children'} && !$self->{'SIGTERM_received'}){
         $self->log('attempting to revive child...');

         if($exit_status == 0){
            $self->log('child exitted with successful exit status, will not revive');
            return 0;
         }

         my $job = $self->get_job($old_child->{'name'} || 'job');

         unless($job){
            $self->log('could not determine job, can not revive child');
            return 0;
         }

         $self->make_fork($job);
      }else{      
         $self->log('revive_children unset, will not attempt to revive child');
      }      

      if($self->{'SIGTERM_received'} && scalar @{$self->{'children'}} == 0){
         $self->log('all processes exitted naturally, exitting...');
         $self->{'exit_callback'}->() if $self->{'exit_callback'};
         exit 0;
      }

      1;
   };

   my $TERM = sub {
       $self->log('SIGTERM received');

       if($self->{'is_child'}){
          if($self->{'SIGTERM_received'}){
             $self->log('second SIGTERM received, forcing exit...');
             exit 0;
          }
          $self->{'SIGTERM_received'} = 1;
          $self->log('waiting for child job to finish before exitting...');
          return 0;
       }

       my $force = 0;

       $force = 1 if $self->{'SIGTERM_received'};

       $self->{'SIGTERM_received'} = 1;

       my $callback = sub {
          $self->log('not all processes exitted naturally, exitting...');
          $self->{'exit_callback'}->() if $self->{'exit_callback'};
          exit 0;
       };

       $self->stop($force, $callback);
   };

   $SIG{'HUP'} = $HUP;
   $SIG{'CHLD'} = $CHLD;
   $SIG{'TERM'} = $TERM;
}

#adds an entry to the log (STDOUT) with pid prepended to the output line
#params:
#   $output - scalar - data to log
#   ...
#return 1
sub log {
   my $self = shift;
   my $output;
   print POSIX::strftime("%m/%d/%Y %H:%M:%S", localtime) . ':' . $$ . ': ' . $output while $output = shift;
}

#starts the daemon processes if they have not been started before
#params:
#   $force - scalar (boolean) - true to force a start
#return 1 on success 0 on failure
sub start {
   my ($self, $force) = @_;

   if($self->{'started'}){
      unless($force){
         $self->log('already started, will not start again without $force');
         return 0;
      }else{
         $self->log('forcing start');
      } 
   }

   $self->{'stopped'} = 0;
   $self->{'started'} = 1;

   $self->log('starting...');

   foreach(@{$self->{'jobs'}}){
      my $job = $_;

      unless($job->{'cmd'}){
         $self->log(($job->{'name'} || 'job') . ' does not have cmd set, skipping');
         next;
      }

      $self->make_fork($job) foreach 0 .. (($job->{'fork_count'} - 1)|| 0);
   }

   1;
}

#stops the daemon, waiting stop_force_time seconds before forcing stop
#params:
#   $force - scalar (boolean) - true to force stop
#   $callback - subroutine reference - called after successful stop (via force or otherwise)
#return 1 on success 0 on failure
sub stop {
   my ($self, $force, $callback) = @_;

   return 0 if $self->{'is_child'};

   unless($self->{'started'}){
      $self->log('daemon not yet started, will not stop');
      return 0;
   }

   if($force){
      $self->log('forcing stop');
      $self->{'force_stop'} = 1;
   }

   if($self->{'stopped'} && !$force){
      $self->log('daemon has already been stopped, will not stop without $force');
      return 0;
   }

   $self->log('stopping...');

   $self->{'stopped'} = 1;

   foreach(@{$self->{'children'}}){
      my $child = $_;

      my $kill_attempts = 0;
 
      $self->log('force killing ' . ($child->{'name'} || 'job') . ' pid ' . $child->{'pid'}) if $force;

      until(kill(($force?'KILL':'TERM'), $child->{'pid'})){
         $kill_attempts++;

         if($kill_attempts > $self->{'kill_attempts'}){
             $self->log('failed to kill ' . $child->{'pid'} . ' after ' . $kill_attempts . ' attempts, will not try again.  Child process may still be running');
             last;
         }
      }
   }
  
   if($force){
      $callback->() if $callback;
      $self->{'force_stop'} = 0;
      $self->{'started'} = 0;
      return 1;
   } 

   $self->log('waiting ' . $self->{'stop_force_time'} . ' seconds for child processes to finish...'); 
 
   alarm $self->{'stop_force_time'};   

   $SIG{'ALRM'} = sub {
      if(scalar @{$self->{'children'}}){
         $self->log('not all child processes have exitted, forcing stop');
         $self->stop(1);
      }

      $self->{'started'} = 0;

      $SIG{'ALRM'} = undef;

      $callback->() if $callback;
   };

   1;
}

#removes a child process from the daemon's watched processes
#params:
#   $pid - scalar - the pid of the child to remove
#return hash reference, the removed child
sub remove_child {
   my ($self, $pid) = @_;

   my @children = ();

   my $ret = undef;

   ($_->{'pid'} == $pid && ($ret = $_)) || push(@children, $_) foreach @{$self->{'children'}};

   $self->{'children'} = \@children;

   $ret;
}

#gets a job from the daemon's job list by name
#params:
#   $name - scalar - the name of the job to fetch
#return hash reference, the job saught after, undef if no job with the given name exists
sub get_job {
   my ($self, $name) = @_;

   foreach(@{$self->{'jobs'}}){
      return $_ if ($_->{'name'} || 'job') eq $name;
   }

   undef;
}

#forks the current process and starts a given job in the child process
#params:
#   $job - hash reference - the job to execute in the child process
#return 1 from parent, child processes never return from this function
sub make_fork {
   my ($self, $job) = @_;

   my $pid = fork;

   if($pid == -1){
      $self->log('there was an error forking');
      return 0;
   }

   if($pid){
      #parent
      $self->log('forked ' . ($job->{'name'} || 'job') . ' to process ' . $pid);
      push @{$self->{'children'}}, {'pid' => $pid, 'name' => $job->{'name'} || 'job'};
   }else{
      #child
      $self->{'is_child'} = 1;
      $self->{'children'} = undef;
      $self->child_proc($job);
   }

   1;
}


#starts a child process's work cycle
#params:
#   $job - hash reference - the job to execute in this cycle
#return 0 if innapropriately called from the parent, child processes never return (exit)
sub child_proc {
   my ($self, $job, $recursion) = @_;

   unless($self->{'is_child'}){
      $self->log('not a child, will not run ' . ($job->{'name'} || 'job'));
      return 0;
   }

   my $exit_status = undef;

   if($self->{'repeat_children'}){
      while(!$self->{'SIGTERM_received'}){
         if($exit_status){
            my $sleep_time = $self->{'sleep_interval'} * (2 ** ($self->{'miss_count'} - 1));
            $self->log(($job->{'name'} || 'job') . ' exited with error status, sleeping ' . $sleep_time . ' seconds...');
            sleep $sleep_time;
         }

         $exit_status = $self->child_job($job);
      }

      $self->log('received SIGTERM');
      $exit_status = 0;
   }else{
      $exit_status = $self->child_job($job);
   }

   $self->log('exitting...');

   exit $exit_status;
}

#executes the job cmd for the given job
#params:
#   $job - hash reference - the job to run
#return scalar, the exit status of the job cmd, undef if inapropriately called form parent
sub child_job {
   my ($self, $job) = @_;

   unless($self->{'is_child'}){
      $self->log('not a child, will not run ' . ($job->{'name'} || 'job'));
      return undef;
   }

   unless($job->{'cmd'}){
      $self->log(($job->{'name'} || 'job') . ' has no cmd, can not perform work');
      return 199;
   }

   my $cmd_output = undef;

   my $exit_status = ::cmd($job->{'cmd'}, $cmd_output);

   $self->log(($job->{'name'} || 'job') . " completed with output:\n$cmd_output") if $cmd_output !~ /^\s*$/;

   $self->log(($job->{'name'} || 'job') . ' complete with exit status ' . $exit_status);

   if($exit_status){
      $self->{'miss_count'}++;
   }else{
      $self->{'miss_count'} = 0;
   }

   return $exit_status;
}

1;
