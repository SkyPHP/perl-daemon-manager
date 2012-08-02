#!/usr/bin/perl -l

#this is a very simple real example demonstrating how to use the daemon
#execute this script and try it out
#monitor output as you send SIGTERM and SIGHUPs the to parent and children processes

require 'Daemon.pl';

#sleep times chosen for easy testing of clean and unclean stop
$params = {
   'jobs' => [
      {'name' => 'ls' , 'cmd' => 'sleep 15', 'fork_count' => 3},
      {'name' => 'perl', 'cmd' => 'sleep 13', 'fork_count' => 2},
      {'name' => 'pwd', 'cmd' => 'sleep 12', 'fork_count' => 1}
   ]
};

$daemon = Daemon->new($params);

$daemon->start();

#our 'main loop' so to speak
sleep(5) while(1);
