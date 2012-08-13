Daemon
======

Daemon is a general-purpose Perl daemon class.  Daemon manages several forked processes which execute commands specified by the Daemon config.  Daemon can be configured either to run jobs once or repeatedly, and to revive dead child processes or not.  Daemon can easily be interfaced with using signals.  A configurable convinience script `Daemon` is included to wrap usage of the Daemon class and provide monitoring of the Daemon process.

Interface
=========
*  SIGTERM - Stops the child processes, allowing them to exit after their current iteration of work.  After `stop_force_time` seconds the the child processes will be forced to exit with SIGKILL.  If a second SIGTERM is received child processes will be sent SIGKILL immediately.  The script will terminate once all child processes exit.   Child processes that receive SIGTERM will exit after the current work iteration, a second SIGTERM will force a child process to exit.  If SIGTERM is sent directly to a child process, the script will revive the child once it exits if `revive_children` is set.
*  SIGHUP - Restarts child processes.  Stops the child processes using the same mechanism as SIGTERM, repeat SIGHUPs will be ignored.

Configuration
=============

The Daemon constuctor accepts a hash reference with the following configurations:
*  `jobs` - A reference to an array of hashes representing jobs.  Job hashes have indices `name`, `cmd`, and `fork_count`.  A job will create `fork_count` child processes executing command `cmd` on the shell.  `name` is useful for logging and job diferentiation.  No two jobs should have the same `name` and no two jobs should ommit `name`.
*  `kill_attempts` - Sometimes the `kill` function fails (usually because a signal handler or some other mechanism already killed the process).  In cases where `kill` fails, the script will try to `kill` again `kill_attempts` times.
*  `revive_children` - If a child process exits with an error code the script will attempt to spawn another child with the same job if `revive_children` is set.
*  `repeat_children` - If this is set child processes will run the command `cmd` of their job in an endless loop.  Otherwise, a child will execute `cmd` only once and will exit with the same exit code as the job command.
*  `sleep_interval` - If a child exits with an error status and `revive_children` is set, the script will `sleep` this amount of time before spawning another child.  With each consecutive error child process, the `sleep` time will be doubled.  60 will become 120 will become 240 and so on.
*  `stop_force_time` - When a stop is requested via SIGTERM, the script will allow this many seconds for child processes to exit cleanly before they are force stopped.  An `alarm` is set, so sending a signal other than SIGALRM will not disrupt this wait time (unlike with `sleep`).
* `exit_callback` - A subroutine reference to be called right before the parent process exits.  Useful for closing filehandles or other cleanup code.

Daemon Attributes
=================

The Daemon object returned by the constructor `new` will have various useful attributes that can be used by the script.  They include all the configurations above as well as:
*  `started` - Value will be set if a job cycle has been started, unset if a cycle has yet to be started or has been stopped.
*  `stopped` - Value will be set if a job cycle has been stopped and another has not yet been started, unset if a cycle is in progress or no cycles have been started.
*  `is_child` - Value will be set if the process is in fact a child process, unset if the process is the parent process.
*  `miss_count` - Scalar holding how many times a child process has exited with an error status consecutively.
*  `force_stop` - Value will be set if a force stop is in progress, unset otherwise.

Daemon Subroutines
==================

See `Daemon.pm` for documentation of the Daemon subroutines.

Daemon Convinience Script
=========================

A command line script, `Daemon`, is included for convinience which starts, stops, restarts or monitors a Daemon process.  The script maintains a pid file and logs for the Daemon.  Sample usages for all of the script's functions are shown bellow.

````
./Daemon start
./Daemon stop #send twice to force immediate (unclean) Daemon termination
./Daemon restart #this is different from a stop followed by a start, sends Daemon SIGHUP
./Daemon status
````

The script expects a file `config.pl` which sets certain variables for the script.  The variables needed in `config.pl` are:
*  `$params` - The hash reference to send to the constructor of the Daemon object.
*  `$pid_file_location` - Where to write the pid file to.
*  `$log_file_location` - Where to redirect STDOUT for the Daemon process.
*  `$error_file_location` - Where to redirect STDERR for the Daemon process.

All of these variables must be set in `config.pl` or the script will exit without doing anything.

Sample Usage
============

Bellow is a sample of usage of the Daemon class.  Run `test.pl` to see the Daemon running.

````
use Daemon;

$jobs = [
   {  #`cd work_dir; ./upload_script` will execute simultaneously in five child processes
      'name' => 'upload_big_files',
      'fork_count' => 5,
      'cmd' => 'cd work_dir; ./upload_script'
   },
   {  #`cd work_dir; ./delete_script` will execute simultaneously in two processes
      'name' => 'delete_big_files',
      'fork_count' => 2,
      'cmd' => 'cd work_dir; ./delete_script'
   }       
];

$params = {
   'jobs' => $jobs,
   'kill_attempts' => 3,   #when stopping the daemon, attempt to kill child processes this many times before giving up
   'revive_children' => 1, #if a child process exits with an error code, it will be restarted if this is set
   'repeat_children' => 1, #if this is set, the job cmd will be executed repeatedly within the child processes, if unset, the child will exit with the cmd exit status
   'sleep_interval' => 60, #if repeat_children is set and a job cmd exits with an error code, child will sleep for this long before re-executing the cmd
                           #for each consecutive error code returned, the amount of time slept will double ie: 60 -> 120 -> 240 ...
   'stop_force_time' => 10 #when stopping the daemon, will wait this long for child processes to terminate cleanly before forcing unclean termination
};

$daemon = Daemon->new($params);

$daemon->start();

sleep 10 while true; #create an endless loop
````
