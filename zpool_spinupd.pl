#!/usr/bin/env perl
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License, Version 1.0 only
# (the "License").  You may not use this file except in compliance
# with the License.
#
# You can obtain a copy of the license at https://solaris.java.net/license.html.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
#
# Copyright 2015 Thomas Geppert All rights reserved.
# Use is subject to license terms.
#


use strict;
use POSIX;

my $DTRACE = "/usr/sbin/dtrace";
my $SDPARM = "/usr/bin/sdparm";
my $LOGFILE = "/var/log/zpool_spinupd.log";


# This Perl script can operate in daemon or command mode.
#
# DAEMON-mode:
# When called with -p as the first parameter and a file name as the second parameter it will
# daemonize and launch a dtrace process that monitors disk spin up. The process ID of the daemon
# process will be written to the specified file.
# If the spin up of a device is detected by dtrace it does execute this script in command mode.
#
# COMMAND-mode:
# In command mode the script expects the major device number and the instance number of a disk
# device as the first and second parameter respectively. If the disk is part of a zpool it
# will spin up all other pool member disks.
#
# The command mode is designed to work in conjunction with the dtrace process launched via the
# daemon mode. Should the script be used directly on the command line, it will spin up all
# accompanying pool disks except for the one specified by the script parameters.
# This is by design to avoid powering up the device that triggered the action in the dtrace
# monitor twice.


###############################
# Start of DAEMON-mode block. #
###############################
if ($ARGV[0] eq "-p" && $#ARGV == 1) {

    require File::Spec;
    require FindBin;

    my ($cwd, $pid);
    my ($spinup_tool, $pidfile);
    my $PIDFILE;

    # Assure that the file which will hold the process ID of the daemon
    # is specified by an absolute path that we can pass to dtrace.
    $pidfile = File::Spec->canonpath($ARGV[1]);
    if (! File::Spec->file_name_is_absolute($pidfile)) {
        chomp($cwd = `pwd`);
        $pidfile = File::Spec->catfile($cwd,$pidfile);
    }
    if (-e $pidfile) {
        printf "[zpool_spinupd] : PID file %s already exists\n", $pidfile;
        printf "[zpool_spinupd] : zpool_spinup daemon is already running\n";
        exit 1;
    }

    # The dtrace monitor that we're about to start as a daemon will use this
    # same script in command mode to perform the disk spin up. Since the working
    # directory of the daemon will be "/" we need to have the absolute path for
    # passing it to dtrace.
    $spinup_tool = File::Spec->catfile($FindBin::RealBin, $FindBin::RealScript);

    # We detach from our parent process and become orphaned.
    $pid = fork;
    exit 0 if $pid;
    die "[zpool_spinupd] : Cannot fork: $!\n" unless defined($pid);

    # We create a new process session and become its leader.
    # As the leader of a new process group we have no controlling terminal.
    POSIX::setsid() || die "[zpool_spinupd] : Can't start a new session: $!\n";

    # By forking a second time we give up session leadership and the possibility
    # to open a new controlling terminal.
    $pid = fork;
    exit 0 if $pid;
    die "[zpool_spinupd] : Cannot fork: $!\n" unless defined($pid);

    # We change our working directory to "/" so that we will not block the
    # unmounting of filesystems.
    chdir '/' || die "[zpool_spinupd] : Cannot change directory to /: $!\n";
    umask 0;
    
    printf "[zpool_spinupd] : Logging to %s\n", $LOGFILE;

    # To complete the daemonization we reopen the standard file descriptors and direct our output
    # to the LOGFILE.
    open(STDIN, "<", "/dev/null") || die "[zpool_spinupd] : Cannot reopen STDIN to /dev/null: $!\n";
    open(STDOUT, ">>", $LOGFILE) || die "[zpool_spinupd] : Cannot reopen STDOUT to logfile $LOGFILE: $!\n";
    open(STDERR, ">>", $LOGFILE) || die "[zpool_spinupd] : Cannot reopen STDOUT to logfile $LOGFILE: $!\n";

    # The PIDFILE holds our PID and will show that the zpool_spinup monitoring daemon is running.
    # dtrace will remove it in the action of the END probe when it receives SIGINT.
    open($PIDFILE, ">", $pidfile) || die "[zpool_spinupd] : Cannot open PIDFILE $pidfile\n";
    print $PIDFILE $$;
    close $PIDFILE;

    # We can now transform our daemonized process into the dtrace monitor.
    # The absolute path to this script is passed as the first macro argument ($$1) to dtrace.
    # dtrace will invoke it in command mode when it detects a disk spin up.
    # The absolute path to the PIDFILE is passed as the second macro argument ($$2).
    # dtrace will remove the file on exit when it receives SIGINT.
    # As a third macro argument ($$3) we pass the process ID of ourselves for logging.
    # 
    #########################
    # Start of dtrace block.#
    #########################
    exec $DTRACE, $spinup_tool, $pidfile, $$, "-n", '

        #pragma D option quiet
        #pragma D option destructive


        /*  Structure that holds the device information of interest. */
        typedef struct pm_devinfo {
            int    major;
            int    instance;
            string driver;
            string type;
            string name;
        } pm_devinfo_t;

        /*
         * The device information is extracted from the first function parameter to
         * pm_raise_power(dev_info_t*, int, int), which is defined in the sunpm.c source file.
         * Since dev_info_t is a forward declaration for an opaque device info handle as found
         * in the dditypes.h header file, the type of args[0] has to be casted in the translator
         * to the actual type of (struct dev_info*) which is defined in the ddi_impldefs.h header file.
        */ 
        translator pm_devinfo_t <dev_info_t *devi> {
            major    = ((struct dev_info*)(devi))->devi_major;
            instance = ((struct dev_info*)(devi))->devi_instance;
            driver   = stringof(((struct dev_info*)(devi))->devi_binding_name);
            type     = stringof(((struct dev_info*)(devi))->devi_node_name);
            name     = stringof(((struct dev_info*)(devi))->devi_addr);
        };


        dtrace:::BEGIN
        {
            system("date %s | tr -d %s", "\"+%F %T\"", "\"\n\"");
            printf(" Monitoring device power up with %s PID:%s\n", $$0, $$3);
            system("date %s | tr -d %s", "\"+%F %T\"", "\"\n\"");
            printf(" Using %s for disk spin up\n", $$1);
        }


        /* 
         * We use the entry into the pm_raise_power(9F) function to detect that a power managed component
         * is about to be powered up and execute the zpool_spinupd script in command mode, which will collect
         * potential other members of a pool and spin them up in parallel. Since spin up is performed via
         * sdparm(8) we do nothing if the execname for this probe event indicates that we catched a disk
         * powering up as a result of our call to zpool_spinupd to prevent from going into a loop.
        */ 
        fbt::pm_raise_power:entry
        /execname != "sdparm" && args[2] == 1/
        {
            system("%s %d %d %s %s %s", $$1,\
                xlate <pm_devinfo_t*> (args[0])->major,\
                xlate <pm_devinfo_t*> (args[0])->instance,\
                xlate <pm_devinfo_t*> (args[0])->driver,\
                xlate <pm_devinfo_t*> (args[0])->type,\
                xlate <pm_devinfo_t*> (args[0])->name);
        }

        /*
         * On exit we need to remove the PIDFILE.
        */
        dtrace:::END
        {
            system("date %s | tr -d %s", "\"+%F %T\"", "\"\n\"");
            printf(" zpool_spinup monitor PID:%s exiting\n", $$3);
            system("rm %s", $$2);
        }
    ' || ( unlink($pidfile) xor die "[zpool_spinupd] : Failed to run dtrace: $!\n");
    #########################
    #  End of dtrace block. #
    #########################
}
###############################
#  End of DAEMON-mode block.  #
###############################



################################
# Start of COMMAND-mode block. #
################################
# We only get here if the script is not started in daemon mode.
# When called from dtrace in cause of an awakening device,
# the following parameters are passed to this script.
# ARGV[0] is the major device number.
# ARGV[1] is the instance number.
# ARGV[2] is the device binding name.
# ARGV[3] is the device type.
# ARGV[4] is the device name.
# The major device number and the instance number are used to identify the device while the other
# parameters are only used for information purpose in the logging output.
# The script performs the following steps.
# 1. Get the zpool configuration.
# 2. Generate a mapping from disk devices to zpools.
# 3. For all pool disks generate a mapping from the major-number,instance-number combination to the
#    disk device name.
# 4. Try to match the script parameters ARGV[0],ARGV[1] to a pool disk.
# 5. In case a match is found, i.e. the device that is going to be powered up is a pool member,
#    check if there are other devices in the pool that need to be powered up.
# 6. Powering up a sibling disk in the pool is performed via the sdparm command.

# This hash array will hold the mapping from major-number,instance-number
# to the unix disk device name, i.e. cXtYdZ.
my %DISK;
# This hash array will hold the device name (cXtYdZ) to pool mapping.
my %POOL;

my @path2inst;
my ($pool, $device, $path, $major, $inst);
my ($trigger_device, $target_pool);


# Get the content of /etc/path_to_inst once now for later mapping the device paths to the instance numbers.
@path2inst = (`cat /etc/path_to_inst`);


# We need the zpool configuration to map disk devices to pools but we cannot get it via the zpool
# command because it would query the pools and block on sleeping disks.
# Therefore we ask zdb for the cached zpool configuration in the /etc/zfs/zpool.cache file.
for (`zdb -C`) {
	# Detect when a new pool section starts.
	if (/(^[a-zA-Z].+?):/) { $pool = $1 }
	# The following will catch the unix device name of a disk,
	elsif (m#^\s+path:\s'/dev/dsk/(.+?)'#) { $device = $1 }
	# which is followed by the physical path of that same disk.
	elsif (m#^\s+phys_path:\s'(.+?)'#) {
		# Now we need to look a little bit around to gather the information
		# required to match a pool disk against the script parameters passed
		# from the dtrace monitor.
		#
		# We need the major device number of the disk.
		$path = $1;
		`ls -l /devices$path` =~ /^.+\s+.+\s+.+\s+.+\s(\d+),\s.+/;
		$major = $1;
		# We also need the instance number of the disk.
		$path =~ s#(.+):.+#$1#;
		for (@path2inst) {
			if (/"$path"\s(\d+)\s.+/) { $inst = $1 }
		}
		# Create the major-number,instance-number hash entry for this disk device.
		$DISK{$major,$inst} = $device;
		# We also store the association with the pool for this disk device.
		$POOL{$device} = $pool;
	}
}


# Check if the awaking device is part of any zpool.
$trigger_device = $DISK{$ARGV[0],$ARGV[1]};
if ($trigger_device) {
	# Identify the awaking pool and find other pool members.
	$target_pool = $POOL{$trigger_device};
	printf "%s Wakeup of disk %s (%d,%d) in zpool %s detected\n",
        POSIX::strftime("%F %T", localtime),
		$trigger_device, $ARGV[0], $ARGV[1], $target_pool;
	# We don't know if the pool has other disks yet.
	# However, this is only required to modify the logging a little bit.
	my $no_other_disks = 1;
	for $device (keys %POOL) {
		if ($POOL{$device} eq $target_pool && $device ne $trigger_device) {
			# OK, we found another disk to spin up and if it's the first one we change
			# our logging massage.
			if ($no_other_disks) {
				$no_other_disks = 0;
				printf "%s Parallel wakeup of zpool disks initiated:\n",
                    POSIX::strftime("%F %T", localtime);
			}
			# Here we send the disk the command to spin up.
			system "$SDPARM --command=start /dev/rdsk/$device &";
		}
	}
	if ($no_other_disks) {
        printf "%s No other disks for parallel wakeup found in zpool %s\n",
            POSIX::strftime("%F %T", localtime), $target_pool;
    }
}
else {
	printf "%s Wakeup of device %s:%s:%s (%d,%d) detected\n",
        POSIX::strftime("%F %T", localtime),
		$ARGV[2], $ARGV[3], $ARGV[4], $ARGV[0], $ARGV[1];
	printf "%s Device is not a member of any zpool\n",
        POSIX::strftime("%F %T", localtime);
}
################################
#  End of COMMAND-mode block.  #
################################
