#!/usr/bin/perl -w
#
# $Id$
#
# File: install.pl
#
# Purpose:  install.pl is the installation script for psad.  It is safe
#           to execute install.pl even if psad has already been installed
#           on a system since install.pl will preserve the existing
#           config section within the new script.
#
# Credits:  (see the CREDITS file)
#
# Version: 0.9.7
#
# Copyright (C) 1999-2002 Michael B. Rash (mbr@cipherdyne.com)
#
# License (GNU Public License):
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307
#    USA
#
# TODO:
#   - make install.pl preserve psad_signatures and psad_auto_ips
#     with "diff" and "patch" from the old to the new.
#########################################################################

use File::Path;
use File::Copy;
use Getopt::Long;
use Text::Wrap;
use Sys::Hostname;
use strict;

### Note that Psad.pm is not included within the above list (installation
### over existing psad should not make use of an old Psad.pm).

### These two variables should not really be changed unless
### you're really sure.
my $PSAD_DIR     = "/var/log/psad";
my $PSAD_CONFDIR = "/etc/psad";

#============== config ===============
my $INSTALL_LOG = "${PSAD_DIR}/install.log";
my $PSAD_FIFO   = "/var/run/psadfifo";
my $INIT_DIR    = "/etc/rc.d/init.d";
my $SBIN_DIR    = "/usr/sbin";  ### consistent with FHS (Filesystem Hierarchy Standard)
my @LOGR_FILES  = (*STDOUT, $INSTALL_LOG);
my $RUNLEVEL;   ### This should only be set if install.pl cannot determine the correct runlevel
my $WHOIS_PSAD  = "/usr/bin/whois.psad";

### system binaries ###
my $chkconfigCmd = "/sbin/chkconfig";
my $mknodCmd     = "/bin/mknod";
my $makeCmd      = "/usr/bin/make";
my $findCmd      = "/usr/bin/find";
my $killallCmd   = "/usr/bin/killall";
my $perlCmd      = "/usr/bin/perl";
my $ipchainsCmd  = "/sbin/ipchains";
my $iptablesCmd  = "/sbin/iptables";
my $psadCmd      = "${SBIN_DIR}/psad";
#============ end config ============

### get the hostname of the system
my $HOSTNAME = hostname;

### scope these vars
my $PERL_INSTALL_DIR;  ### This is used to find pre-0.9.2 installations of psad

### set the install directory for the Psad.pm module
my $found = 0;
for my $d (@INC) {
    if ($d =~ /site_perl\/\d\S+/) {
        $PERL_INSTALL_DIR = $d;
        $found = 1;
        last;
    }
}
unless ($found) {
    $PERL_INSTALL_DIR = $INC[0];
}

### set the default execution
my $SUB_TAB = "     ";
my $execute_psad = 0;
my $nopreserve   = 0;
my $uninstall    = 0;
my $verbose      = 0;
my $help         = 0;

&usage_and_exit(1) unless (GetOptions (
    'no_preserve' => \$nopreserve,    # don't preserve existing configs
    'exec_psad'   => \$execute_psad,
    'uninstall'   => \$uninstall,
    'verbose'     => \$verbose,
    'help'        => \$help           # display help
));
&usage_and_exit(0) if ($help);

my %Cmds = (
    "mknod"    => $mknodCmd,
    "find"     => $findCmd,
    "make"     => $makeCmd,
    "killall"  => $killallCmd,
    "perl"     => $perlCmd,
    "ipchains" => $ipchainsCmd,
    "iptables" => $iptablesCmd,
);

my $distro = &get_distro();

### add chkconfig only if we are runing on a redhat distro
if ($distro =~ /redhat/) {
    $Cmds{'chkconfig'} = $chkconfigCmd;
}

### need to make sure this exists before attempting to
### write anything to the install log.
&create_psaddir();

&check_commands(\%Cmds);
$Cmds{'psad'} = $psadCmd;

### check to make sure we are running as root
$< == 0 && $> == 0 or die "You need to be root (or equivalent UID 0" .
                          " account) to install/uninstall psad!\n";

&check_old_psad_installation();  ### check for a pre-0.9.2 installation of psad.

if ($uninstall) {
    my $t = localtime();
    my $time = " ... Uninstalling psad from $HOSTNAME: $t\n";
    &logr("\n$time\n");

    my $ans = "";
    while ($ans ne "y" && $ans ne "n") {
        print wrap("", $SUB_TAB, " ... This will completely remove psad from your system.  Are you sure (y/n)? ");
        $ans = <STDIN>;
        chomp $ans;
    }
    if ($ans eq "n") {
        &logr(" @@@ User aborted uninstall by answering \"n\" to the remove question!  Exiting.\n");
        exit 0;
    }
    ### after this point, psad will really be uninstalled so stop writing stuff to
    ### the install.log file.  Just print everything to STDOUT
    if (-e "${SBIN_DIR}/psad" && system "${SBIN_DIR}/psad --Status > /dev/null") {
        print " ... Stopping psad daemons!\n";
        if (-e "${INIT_DIR}/psad") {
            system "${INIT_DIR}/psad stop";
        } else {
            system "${SBIN_DIR}/psad --Kill";
        }
    }
    if (-e "${SBIN_DIR}/psad") {
        print wrap("", $SUB_TAB, " ... Removing psad daemons: ${SBIN_DIR}/(psad, psadwatchd, kmsgsd, diskmond)\n");
        unlink "${SBIN_DIR}/psad"       or warn "@@@@@  Could not remove ${SBIN_DIR}/psad!!!\n";
        unlink "${SBIN_DIR}/psadwatchd" or warn "@@@@@  Could not remove ${SBIN_DIR}/psadwatchd!!!\n";
        unlink "${SBIN_DIR}/kmsgsd"     or warn "@@@@@  Could not remove ${SBIN_DIR}/kmsgsd!!!\n";
        unlink "${SBIN_DIR}/diskmond"   or warn "@@@@@  Could not remove ${SBIN_DIR}/diskmond!!!\n";
    }
    if (-e "${INIT_DIR}/psad") {
        print " ... Removing ${INIT_DIR}/psad\n";
        unlink "${INIT_DIR}/psad";
    }
    ### deal with the uninstallation of Psad.pm later...
    if (-e "${PERL_INSTALL_DIR}/Psad.pm") {
        print " ----  Removing ${PERL_INSTALL_DIR}/Psad.pm  ----\n";
        unlink "${PERL_INSTALL_DIR}/Psad.pm";
    }
    if (-d $PSAD_CONFDIR) {
        print " ... Removing configuration directory: $PSAD_CONFDIR\n";
        rmtree($PSAD_CONFDIR, 1, 0);
    }
    if (-d $PSAD_DIR) {
        print " ... Removing logging directory: $PSAD_DIR\n";
        rmtree($PSAD_DIR, 1, 0);
    }
    if (-e $PSAD_FIFO) {
        print " ... Removing named pipe: $PSAD_FIFO\n";
        unlink $PSAD_FIFO;
    }
    if (-e $WHOIS_PSAD) {
        print " ... Removing $WHOIS_PSAD\n";
        unlink $WHOIS_PSAD;
    }
    print " ... Restoring /etc/syslog.conf.orig -> /etc/syslog.conf\n";
    if (-e "/etc/syslog.conf.orig") {
        move("/etc/syslog.conf.orig", "/etc/syslog.conf");
    } else {
        print wrap("", $SUB_TAB, " ... /etc/syslog.conf.orig does not exist.  Editing /etc/syslog.conf directly.\n");
        open ESYS, "< /etc/syslog.conf" or die "@@@@@  Unable to open /etc/syslog.conf: $!\n";
        my @sys = <ESYS>;
        close ESYS;
        open CSYS, "> /etc/syslog.conf";
        for my $s (@sys) {
            chomp $s;
            print CSYS "$s\n" if ($s !~ /psadfifo/);  ### don't print the psadfifo line
        }
        close CSYS;
    }
    print " ... Restarting syslog.\n";
    system("$Cmds{'killall'} -HUP syslogd");
    print "\n";
    print " ... Psad has been uninstalled!\n";
    exit 0;
}

### Start the installation code...

### make sure install.pl is being called from the source directory
unless (-e "psad" && -e "Psad.pm/Psad.pm") {
    die "\n@@@@@  install.pl can only be executed from the directory" .
                       " that contains the psad sources!  Exiting.\n\n";
}

my $t = localtime();
my $time = " ... Installing psad on $HOSTNAME: $t\n";
&logr("\n$time\n");

unless (-e $PSAD_FIFO) {
    &logr(" ... Creating named pipe $PSAD_FIFO\n");
    ### create the named pipe
    `$Cmds{'mknod'} -m 600 $PSAD_FIFO p`;    ### die does not seem to work right here.
    unless (-e $PSAD_FIFO) {
        die "@@@@@  Could not create the named pipe \"$PSAD_FIFO\"!" .
            "\n@@@@@  Psad requires this file to exist!  Aborting install.\n";
    }
}
### make sure syslog is sending kern.info messages to psadfifo
unless (open SYSLOG, "< /etc/syslog.conf" and grep /kern\.info\s+\|\s*$PSAD_FIFO/, <SYSLOG> and close SYSLOG) {
    &logr(" ... Modifying /etc/syslog.conf\n");
    copy("/etc/syslog.conf", "/etc/syslog.conf.orig") unless (-e "/etc/syslog.conf.orig");
    open SYSLOG, ">> /etc/syslog.conf" or die "@@@@@  Unable to open /etc/syslog.conf: $!\n";
    print SYSLOG "kern.info		|$PSAD_FIFO\n\n";  ### reinstate kernel logging to our named pipe
    close SYSLOG;
    print " ... Restarting syslog.\n";
    system("$Cmds{'killall'} -HUP syslogd");
}
unless (-d $PSAD_DIR) {
    &logr(" ... Creating $PSAD_DIR\n");
    mkdir $PSAD_DIR,0400;
}
unless (-e "${PSAD_DIR}/fwdata") {
    &logr(" ... Creating ${PSAD_DIR}/fwdata file\n");
    open F, "> ${PSAD_DIR}/fwdata";
    close F;
    chmod 0600, "${PSAD_DIR}/fwdata";
    &perms_ownership("${PSAD_DIR}/fwdata", 0600);
}
unless (-d $SBIN_DIR) {
    &logr(" ... Creating $SBIN_DIR\n");
    mkdir $SBIN_DIR,0755;
}
if (-d "whois-4.5.21") {
    &logr(" ... Compiling Marco d'Itri's whois client\n");
    if (! system("$Cmds{'make'} -C whois-4.5.21")) {  # remember unix return value...
        &logr(" ... Copying whois binary to $WHOIS_PSAD\n");
        copy("whois-4.5.21/whois", $WHOIS_PSAD);
    }
}
&perms_ownership($WHOIS_PSAD, 0755);

### installing Psad.pm
&logr(" ... Installing the Psad.pm perl module\n");

chdir "Psad.pm";
unless (-e "Makefile.PL" && -e "Psad.pm") {
    die "@@@@@  Your source kit appears to be incomplete!  Psad.pm is missing.\n";
}
system "$Cmds{'perl'} Makefile.PL";
system "$Cmds{'make'}";
system "$Cmds{'make'} test";
system "$Cmds{'make'} install";
chdir "..";

print "\n\n";

### installing Unix::Syslog
&logr(" ... Installing the Unix::Syslog perl module\n");
    
chdir "Unix-Syslog-0.98";
unless (-e "Makefile.PL" && -e "Syslog.pm") {
    die "@@@@@  Your source kit appears to be incomplete!  Syslog.pm is missing.\n";
}
system "$Cmds{'perl'} Makefile.PL";
system "$Cmds{'make'}";
system "$Cmds{'make'} test";
system "$Cmds{'make'} install";
chdir "..";

print "\n\n";

### put the psad daemons in place
&logr(" ... Copying psad -> ${SBIN_DIR}/psad\n");
copy("psad", "${SBIN_DIR}/psad");
&perms_ownership("${SBIN_DIR}/psad", 0500);

&logr(" ... Copying psadwatchd -> ${SBIN_DIR}/psadwatchd\n");
copy("psadwatchd", "${SBIN_DIR}/psadwatchd");
&perms_ownership("${SBIN_DIR}/psadwatchd", 0500);

&logr(" ... Copying kmsgsd -> ${SBIN_DIR}/kmsgsd\n");
copy("kmsgsd", "${SBIN_DIR}/kmsgsd");
&perms_ownership("${SBIN_DIR}/kmsgsd", 0500);

&logr(" ... Copying diskmond -> ${SBIN_DIR}/diskmond\n");
copy("diskmond", "${SBIN_DIR}/diskmond");
&perms_ownership("${SBIN_DIR}/diskmond", 0500);

### Give the admin the opportunity to add to the strings that are normally
### checked in iptables messages.  This is useful since the admin may have
### configured the firewall to use a logging prefix of "Audit" or something
### else other than the normal "DROP", "DENY", or "REJECT" strings.
my $append_fw_search_str = &get_fw_search_string();

#my $email_str = "";
#if ( -e "${SBIN_DIR}/psad" && (! $nopreserve)) {  # need to grab the old config
#    &logr(" ... Copying psad -> ${SBIN_DIR}/psad\n");
#    &logr("     Preserving old config within ${SBIN_DIR}/psad\n");
#    &preserve_config("psad", "${SBIN_DIR}/psad");
#    $email_str = &query_email("${SBIN_DIR}/psad");
#    copy("psad", "${SBIN_DIR}/psad");
#    if ($email_str) {
#        &put_email("${SBIN_DIR}/psad", $email_str);
#    }
#    if ($append_fw_search_str) {
#        &logr(" ... Appending \"$append_fw_search_str\" to \$FW_MSG_SEARCH in ${SBIN_DIR}/psad\n");
#        &put_fw_search_str("${SBIN_DIR}/psad", $append_fw_search_str);
#    }
#    &perms_ownership("${SBIN_DIR}/psad", 0500)
#} else {
#    &logr(" ... Copying psad -> ${SBIN_DIR}/\n");
#    copy("psad", "${SBIN_DIR}/psad");
#    $email_str = &query_email("${SBIN_DIR}/psad");
#    if ($email_str) {
#        &put_email("${SBIN_DIR}/psad", $email_str);
#    }
#    if ($append_fw_search_str) {
#        &logr(" ... Appending \"$append_fw_search_str\" to \$FW_MSG_SEARCH in ${SBIN_DIR}/psad\n");
#        &put_fw_search_str("${SBIN_DIR}/psad", $append_fw_search_str);
#    }
#    &perms_ownership("${SBIN_DIR}/psad", 0500);
#}
unless (-d $PSAD_CONFDIR) {
    &logr(" ... Creating $PSAD_CONFDIR\n");
    mkdir $PSAD_CONFDIR,0400;
}
if (-e "${PSAD_CONFDIR}/psad_signatures") {
    &logr(" ... Copying psad_signatures -> ${PSAD_CONFDIR}/psad_signatures\n");
    &logr("     Preserving old signatures file as ${PSAD_CONFDIR}/psad_signatures.old\n");
    move("${PSAD_CONFDIR}/psad_signatures", "${PSAD_CONFDIR}/psad_signatures.old");
    copy("psad_signatures", "${PSAD_CONFDIR}/psad_signatures");
    &perms_ownership("${PSAD_CONFDIR}/psad_signatures", 0600);
} else {
    &logr(" ... Copying psad_signatures -> ${PSAD_CONFDIR}/psad_signatures\n");
    copy("psad_signatures", "${PSAD_CONFDIR}/psad_signatures");
    &perms_ownership("${PSAD_CONFDIR}/psad_signatures", 0600);
}
if (-e "${PSAD_CONFDIR}/psad_auto_ips") {
    &logr(" ... Copying psad_auto_ips -> ${PSAD_CONFDIR}/psad_auto_ips\n");
    &logr("     Preserving old auto_ips file as ${PSAD_CONFDIR}/psad_auto_ips.old\n");
    move("${PSAD_CONFDIR}/psad/psad_auto_ips", "${PSAD_CONFDIR}/psad_auto_ips.old");
    copy("psad_auto_ips", "${PSAD_CONFDIR}/psad_auto_ips");
    &perms_ownership("${PSAD_CONFDIR}/psad_auto_ips", 0600);
} else {
    &logr(" ... Copying psad_auto_ips -> ${PSAD_CONFDIR}/psad_auto_ips\n");
    copy("psad_auto_ips", "${PSAD_CONFDIR}/psad_auto_ips");
    &perms_ownership("${PSAD_CONFDIR}/psad_auto_ips", 0600);
}
if (-e "${PSAD_CONFDIR}/psad.conf") {
    ### deal with preserving existing config here

    &preserve_psad_config() unless $nopreserve;

    &logr(" ... Copying psad.conf -> ${PSAD_CONFDIR}/psad.conf\n");
    &logr("     Preserving old psad.conf file as ${PSAD_CONFDIR}/psad.conf\n");
    move("${PSAD_CONFDIR}/psad.conf", "${PSAD_CONFDIR}/psad.conf.old");
    copy("psad.conf", "${PSAD_CONFDIR}/psad.conf");
    &perms_ownership("${PSAD_CONFDIR}/psad.conf", 0600);
} else {
    &logr(" ... Copying psad.conf -> ${PSAD_CONFDIR}/psad.conf\n");
    copy("psad.conf", "${PSAD_CONFDIR}/psad.conf");
    &perms_ownership("${PSAD_CONFDIR}/psad.conf", 0600);
}
if (-e "/etc/man.config") {
    ### prefer to install psad.8 in /usr/local/man/man8 if this directory is configured in /etc/man.config
    if (open MPATH, "< /etc/man.config" and grep /MANPATH\s+\/usr\/local\/man/, <MPATH> and close MPATH) {
        &logr(" ... Installing psad(8) man page as /usr/local/man/man8/psad.8\n");
        copy("psad.8", "/usr/local/man/man8/psad.8");
        &perms_ownership("/usr/local/man/man8/psad.8", 0644);
    } else {
        my $mpath;
        open MPATH, "< /etc/man.config";
        while(<MPATH>) {
            my $line = $_;
            chomp $line;
            if ($line =~ /^MANPATH\s+(\S+)/) {
                $mpath = $1;
                last;
            }
        }
        close MPATH;
        if ($mpath) {
            my $path = $mpath . "/man8/psad.8";
            &logr(" ... Installing psad(8) man page as $path\n");
            copy("psad.8", $path);
            &perms_ownership($path, 0644);
        } else {
            &logr(" ... Installing psad(8) man page as /usr/man/man8/psad.8\n");
            copy("psad.8", "/usr/man/man8/psad.8");
            &perms_ownership("/usr/man/man8/psad.8", 0644);
        }
    }
} else {
    &logr(" ... Installing psad(8) man page as /usr/man/man8/psad.8\n");
    copy("psad.8", "/usr/man/man8/psad.8");
    &perms_ownership("/usr/man/man8/psad.8", 0644);
}

if ($distro =~ /redhat/) {
    if (-d $INIT_DIR) {
        &logr(" ... Copying psad-init -> ${INIT_DIR}/psad\n");
        copy("psad-init", "${INIT_DIR}/psad");
        &perms_ownership("${INIT_DIR}/psad", 0744);
        &enable_psad_at_boot($distro);
        # remove signature checking from psad process if we are not running an iptables-enabled kernel
#       system "$Cmds{'perl'} -p -i -e 's|\\-s\\s/etc/psad/psad_signatures||' ${INIT_DIR}/psad" if ($kernel !~ /^2.3/ && $kernel !~ /^2.4/);
    } else {
        &logr("@@@@@  The init script directory, \"${INIT_DIR}\" does not exist!.\n");
        &logr("Edit the \$INIT_DIR variable in the config section to point to where the init scripts are.\n");
    }
} else {  ### psad is being installed on a non-redhat distribution
    if (-d $INIT_DIR) {
        &logr(" ... Copying psad-init.generic -> ${INIT_DIR}/psad\n");
        copy("psad-init.generic", "${INIT_DIR}/psad");
        &perms_ownership("${INIT_DIR}/psad", 0744);
        &enable_psad_at_boot($distro);
        # remove signature checking from psad process if we are not running an iptables-enabled kernel
#       system "$Cmds{'perl'} -p -i -e 's|\\-s\\s/etc/psad/psad_signatures||' ${INIT_DIR}/psad" if ($kernel !~ /^2.3/ && $kernel !~ /^2.4/);
    } else {
        &logr("@@@@@  The init script directory, \"${INIT_DIR}\" does not exist!.  Edit the \$INIT_DIR variable in the config section.\n");
    }
}
my $running;
my $pid;
if (-e "/var/run/psad.pid") {
    open PID, "< /var/run/psad.pid";
    $pid = <PID>;
    close PID;
    chomp $pid;
    $running = kill 0, $pid;
} else {
    $running = 0;
}
if ($execute_psad) {
    if ($distro =~ /redhat/) {
        if ($running) {
            &logr(" ... Restarting the psad daemons...\n");
            system "${INIT_DIR}/psad restart";
        } else {
            &logr(" ... Starting the psad daemons...\n");
            system "${INIT_DIR} -s ${PSAD_CONFDIR}/psad_signatures -a ${PSAD_CONFDIR}/psad_auto_ips";
        }
    } else {
        if ($running) {
            &logr(" ... Restarting the psad daemons...\n");
            system "$Cmds{'psad'} --Restart";
        } else {
            &logr(" ... Starting the psad daemons...\n");
            system "$Cmds{'psad'} -s ${PSAD_CONFDIR}/psad_signatures -a ${PSAD_CONFDIR}/psad_auto_ips";
        }
    }
} else {
    if ($distro =~ /redhat/) {
        if ($running) {
            &logr(" ... An older version of psad is already running.  To execute, run \"${INIT_DIR}/psad restart\"\n");
        } else {
            &logr(" ... To execute psad, run \"${INIT_DIR}/psad start\"\n");
        }
    } else {
        if ($running) {
            &logr(" ... An older version of psad is already running.  kill pid $pid, and then execute:\n");
            &logr("${SBIN_DIR}/psad -s ${PSAD_CONFDIR}/psad_signatures -a ${PSAD_CONFDIR}/psad_auto_ips\n");
        } else {
            &logr("To start psad, execute: ${SBIN_DIR}/psad -s ${PSAD_CONFDIR}/psad_signatures -a ${PSAD_CONFDIR}/psad_auto_ips\n");
        }
    }
}
&logr("\n ... Psad has been installed!\n");

exit 0;
#==================== end main =====================
sub check_old_psad_installation() {
    my $old_install_dir = "/usr/local/bin";
    move("${old_install_dir}/psad", "${SBIN_DIR}/psad") if (-e "${old_install_dir}/psad");
    move("${old_install_dir}/psadwatchd", "${SBIN_DIR}/psadwatchd") if (-e "${old_install_dir}/psadwatchd");
    move("${old_install_dir}/diskmond", "${SBIN_DIR}/diskmond") if (-e "${old_install_dir}/diskmond");
    move("${old_install_dir}/kmsgsd", "${SBIN_DIR}/kmsgsd") if (-e "${old_install_dir}/kmsgsd");
    ### Psad.pm will be installed The Right Way using make
    unlink "${PERL_INSTALL_DIR}/Psad.pm" if (-e "${PERL_INSTALL_DIR}/Psad.pm");
    return;
}
sub get_distro() {
    if (-e "/etc/issue") {
        ### Red Hat Linux release 6.2 (Zoot)
        open ISSUE, "< /etc/issue";
        while(<ISSUE>) {
            my $l = $_;
            chomp $l;
            return "redhat" if ($l =~ /Red\sHat/i);
        }
        close ISSUE;
        return "NA";
    } else {
        return "NA";
    }
}
#sub build_psad_config() {
#sub preserve_psad_config() {
    
sub preserve_config() {
    my ($srcfile, $productionfile) = @_;
    my $start = 0;
    my @config = ();
    my @defconfig = ();
    open PROD, "< $productionfile" or die "Could not open production file: $!\n";
    GETCONFIG: while(<PROD>) {
        my $l = $_;
        chomp $l;
        if ($l =~ /\=\=\=\=\=\s+config\s+\=\=\=\=\=/) {
            $start = 1;
        }
        push @config, $l if ($start);
        if ($l =~ /\=\=\=\=\=\s+end\s+config\s+\=\=\=\=\=/) {
            last GETCONFIG;
        }
    }
    close PROD;
    if ($config[0] !~ /\=\=\=\=\=\s+config\s+\=\=\=\=\=/ || $config[$#config] !~ /\=\=\=\=\=\s+end\s+config\s+\=\=\=\=\=/) {
        die "Could not get config info from $productionfile!!!  Try running \"install.pl -n\" and\nedit the configuration sections of $productionfile directly.\n"
    }
    $start = 0;
    open DEFCONFIG, "< $srcfile" or die "Could not open source file: $!\n";
    GETDEFCONFIG: while(<DEFCONFIG>) {
        my $l = $_;
        chomp $l;
                if ($l =~ /\=\=\=\=\=\s+config\s+\=\=\=\=\=/) {
                        $start = 1;
                }
        push @defconfig, $l if ($start);
        if ($l =~ /\=\=\=\=\=\s+end\s+config\s+\=\=\=\=\=/) {
                        last GETDEFCONFIG;
                }
    }
    close DEFCONFIG;
    # We only want to preserve the variables from the $productionfile.  Any commented lines will be discarded
    # and replaced with the commented lines from the $srcfile.
    #
    # First get the variables into a hash from the $productionfile
    my %prodvars;
    my %srcvars;
    undef %prodvars;
    undef %srcvars;
    for my $p (@config) {
        if ($p =~ /(\S+)\s+=\s+(.*?)\;/) {
            my ($varname, $value) = ($1, $2);
            my $type;
            ($varname, $type) = &assign_var_type($varname);
            $prodvars{$type}{$varname}{'VALUE'} = $value;
            $prodvars{$type}{$varname}{'LINE'} = $p;
            $prodvars{$type}{$varname}{'FOUND'} = "N";
            if ($p =~ /^my/) {
                $prodvars{$type}{$varname}{'MY'} = "Y";
            } else {
                $prodvars{$type}{$varname}{'MY'} = "N";
            }
        }
    }
    open SRC, "< $srcfile" or die "Could not open source file: $!\n";
    $start = 0;
    my $print = 1;
    my $prod_tmp = $productionfile . "_tmp";
    open TMP, "> $prod_tmp";
    while(<SRC>) {
        my $l = $_;
        chomp $l;
        $start = 1 if ($l =~ /\=\=\=\=\=\s+config\s+\=\=\=\=\=/);
        print TMP "$l\n" unless $start;   # print the "======= config =======" line
        if ($start && $print) {
            PDEF: for my $defc (@defconfig) {
                if ($defc =~ /^\s*#/) {   ### found a comment
                    print TMP "$defc\n";
                    next PDEF;
                }
                if ($defc =~ /(\S+)\s+=\s+(.*?)\;/) {  # found a variable
                    my ($varname, $value) = ($1, $2);
                    my $type;
                    ($varname, $type) = &assign_var_type($varname);
                    if ($varname eq "EMAIL_ADDRESSES" && defined $prodvars{'STRING'}{'EMAIL_ADDRESS'}{'VALUE'}) {  # old email format in production psad
                        if ($prodvars{'STRING'}{'EMAIL_ADDRESS'}{'VALUE'} =~ /\"(\S+).\@(\S+)\"/) {
                            my $mailbox = $1;
                            my $host = $2;
                            if ($mailbox ne "root" && $host ne "localhost") {
                                $defc =~ s/root/$mailbox/;
                                $defc =~ s/localhost/$host/;
                                &logr(" ... Removing depreciated email format.  Preserving email address in production installation.\n");
                                $prodvars{'STRING'}{'EMAIL_ADDRESS'}{'FOUND'} = "Y";
                                print TMP "$defc\n";
                                next PDEF;
                            }
                        }
                    }
                    if (defined $prodvars{$type}{$varname}{'VALUE'}) {
                        if ($prodvars{$type}{$varname}{'MY'} eq "N" && $defc =~ /^my/) {
                            $prodvars{$type}{$varname}{'LINE'} = "my " . $prodvars{$type}{$varname}{'LINE'};
                        }
                        $defc = $prodvars{$type}{$varname}{'LINE'};
                        $prodvars{$type}{$varname}{'FOUND'} = "Y";
                        if ($verbose) {
                            &logr("*****  Using configuration value from production installation of $srcfile for $type variable: $varname\n");
                        }
                        print TMP "$defc\n";
                    } else {
                        $prodvars{$type}{$varname}{'FOUND'} = "Y";
                        &logr("++++ Adding new configuration $type variable \"$varname\" introduced in this version of $srcfile.\n");
                        print TMP "$defc\n";
                    }
                } else {
                    print TMP "$defc\n";  # it is some other non-variable-assignment line so print it from the $srcfile
                }
            }
            for my $type (keys %prodvars) {
                for my $varname (keys %{$prodvars{$type}}) {
                    next if ($varname =~ /EMAIL_ADDRESS/);
                    unless ($prodvars{$type}{$varname}{'FOUND'} eq "Y") {
                        &logr("---- Removing depreciated $type variable: \"$varname\" not needed in this version of $srcfile.\n");
                    }
                }
            }
            $print = 0;
        }
        $start = 0 if ($l =~ /\=\=\=\=\=\s+end\s+config\s+\=\=\=\=\=/);
    }
    close SRC;
    close TMP;
    move($prod_tmp, $productionfile);
    return;
}
sub striphashsyntax() {
    my $varname = shift;
    $varname =~ s/\{//;
    $varname =~ s/\}//;
    $varname =~ s/\'//g;
    return $varname;
}
sub assign_var_type() {
    my $varname = shift;;
    my $type;
    if ($varname =~ /\$/ && $varname =~ /\{/) {
        $type = "HSH_ELEM";
        $varname = &striphashsyntax($varname);   # $DANGER_LEVELS{'1'}, etc...
    } elsif ($varname =~ /\$/) { 
        $type = "STRING";
    } elsif ($varname =~ /\@/) {
        $type = "ARRAY";
    } elsif ($varname =~ /\%/) {  # this will probably never get used since psad will just scope a hash in the config section with "my"
        $type = "HASH";
    }
    $varname =~ s/^.//;  # get rid of variable type since we have it in $type
    return $varname, $type;
}
sub perms_ownership() {
    my ($file, $perm_value) = @_;
    chmod $perm_value, $file;
    chown 0, 0, $file;  # chown uid, gid, $file
    return;
}
sub create_psaddir() {
    unless (-d $PSAD_DIR) {
        mkdir $PSAD_DIR, 0400;
    }
    return;
}
sub get_fw_search_string() {
    print " ... psad checks the firewall configuration on the underlying machine\n"
        . "     to see if packets will be logged and dropped that have not\n"
        . "     explicitly allowed through.  By default psad looks for the\n"
        . "     strings \"DENY\", \"DROP\", or \"REJECT\". However, if your\n"
        . "     particular firewall configuration logs blocked packets with the\n"
        . "     string \"Audit\" for example, psad can be configured to look for this\n"
        . "     string.\n\n";
    my $ans = "";
    while ($ans ne "y" && $ans ne "n") {
        print "     Would you like to add a new string that will be used to analyze\n"
            . "     firewall log messages?  (Is it usually safe to say \"n\" here).\n"
            . "     (y/[n])? ";
        $ans = <STDIN>;
        chomp $ans;
    }
    print "\n";
    my $fw_string = "";
    if ($ans eq "y") {
        print "     Enter a string (i.e. \"Audit\"):  ";
        $fw_string = <STDIN>;
        chomp $fw_string;
    }
    return $fw_string;
}
sub query_email() {
    my $file = shift;
    open F, "< $file";
    my @lines = <F>;
    close F;
    my $email_address;
    for my $l (@lines) {
        chomp $l;
        if ($l =~ /my\s*\@EMAIL_ADDRESSES\s*=\s*qw\s*\((.+)\)/) {
            $email_address = $1;
            last;
        }
    }
    unless ($email_address) {
        return 0;
    }
    my @ftmp = split /\//, $file;
    my $filename = $ftmp[$#ftmp];
    print " ... $filename alerts will be sent to:\n\n";
    print "       $email_address\n\n";
    my $ans = "";
    while ($ans ne "y" && $ans ne "n") {
        print " ... Would you like alerts sent to a different address (y/n)?  ";
        $ans = <STDIN>;
        chomp $ans;
    }
    print "\n";
    if ($ans eq "y") {
        print "\n";
        print " ... To which email address(es) would you like $filename alerts to be sent?\n";
        print " ... You can enter as many email addresses as you like separated by spaces.\n";
        my $emailstr = "";
        my $correct = 0;
        while (! $correct) {
            print "Email addresses: ";
            $emailstr = <STDIN>;
            $emailstr =~ s/\,//g;
            chomp $emailstr;
            my @emails = split /\s+/, $emailstr;
            $correct = 1;
            for my $email (@emails) {
                unless ($email =~ /\S+\@\S+/) {
                    $correct = 0;
                }
            }
            $correct = 0 unless @emails;
        }
        return $emailstr;
    } else {
        return "";
    }
    return "";
}
sub put_email() {
    my ($file, $emailstr) = @_;
    my $tmp = $file . ".tmp";
    move($file, $tmp);
    open TMP, "< $tmp";
    my @lines = <TMP>;
    close TMP;
    unlink $tmp;
    my @ftmp = split /\//, $file;
    my $filename = $ftmp[$#ftmp];

    open F, "> $file";
    for my $l (@lines) {
        if ($l =~ /my\s*\@EMAIL_ADDRESSES\s*=\s*qw\(\s*(\S+)/) {
            print F "my \@EMAIL_ADDRESSES = qw($emailstr);\n";
        } else {
            print F $l;
        }
    }
    close F;
    return;
}
sub put_fw_search_str() {
    my ($file, $append_fw_search) = @_;
    my $tmp = $file . ".tmp";
    move($file, $tmp);
    open TMP, "< $tmp";
    my @lines = <TMP>;
    close TMP;
    unlink $tmp;
    my @ftmp = split /\//, $file;
    my $filename = $ftmp[$#ftmp];

    open F, "> $file";
    for my $l (@lines) {
        if ($l =~ /my\s*\$FW_MSG_SEARCH\s*=\s*\"(.*)\"\;/) {
            my $fw_string = $1;
            $fw_string .= "|$append_fw_search";
            print F "my \$FW_MSG_SEARCH = \"$fw_string\";\n";
        } else {
            print F $l;
        }
    }
    close F;
    return;
}
sub enable_psad_at_boot() {
    my $distro = shift;
    my $ans = "";
    while ($ans ne "y" && $ans ne "n") {
        print " ... Enable psad at boot time (y/n)?  ";
        $ans = <STDIN>;
        chomp $ans;
    }
    if ($ans eq "y") {
        if ($distro =~ /redhat/) {
            system "$Cmds{'chkconfig'} --add psad";
        } else {  ### it is a non-redhat distro, try to get the runlevel from /etc/inittab
            if ($RUNLEVEL) {
                unless (-e "/etc/rc.d/rc${RUNLEVEL}.d/S99psad") {  ### the link already exists, so don't re-create it
                    symlink "/etc/rc.d/init.d/psad", "/etc/rc.d/rc${RUNLEVEL}.d/S99psad";
                }
            } elsif (-e "/etc/inittab") {
                open I, "< /etc/inittab";
                my @ilines = <I>;
                close I;
                for my $l (@ilines) {
                    chomp $l;
                    if ($l =~ /^id\:(\d)\:initdefault/) {
                        $RUNLEVEL = $1;
                        last;
                    }
                }
                unless ($RUNLEVEL) {
                    print "@@@@@  Could not determine the runlevel.  Set the runlevel\nmanually in the config section of install.pl\n";
                    return;
                }
                unless (-e "/etc/rc.d/rc${RUNLEVEL}.d/S99psad") {  ### the link already exists, so don't re-create it
                    symlink "/etc/rc.d/init.d/psad", "/etc/rc.d/rc${RUNLEVEL}.d/S99psad";
                }
            } else {
                print "@@@@@  /etc/inittab does not exist!  Set the runlevel\nmanually in the config section of install.pl.\n";
                return;
            }
        }
    }
    return;
}
### check paths to commands and attempt to correct if any are wrong.
sub check_commands() {
    my $Cmds_href = shift;
    my $caller = $0;
    my @path = qw(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin);
    CMD: for my $cmd (keys %$Cmds_href) {
        my $cmd_name = ($Cmds_href->{$cmd} =~ m|.*/(.*)|);
        unless (-x $Cmds_href->{$cmd}) {
            my $found = 0;
            PATH: for my $dir (@path) {
                if (-x "${dir}/${cmd}") {
                    $Cmds_href->{$cmd} = "${dir}/${cmd}";
                    $found = 1;
                    last PATH;
                }
            }
            unless ($found) {
                next CMD if ($cmd eq "ipchains" || $cmd eq "iptables");
                die "\n@@@@@  ($caller): Could not find $cmd anywhere!!!  Please" .
                    " edit the config section to include the path to $cmd.\n";
            }
        }
        unless (-x $Cmds_href->{$cmd}) {
            die "\n@@@@@  ($caller):  $cmd_name is located at $Cmds_href->{$cmd}" .
                                            " but is not executable by uid: $<\n";
        }
    }
    return;
}
### logging subroutine that handles multiple filehandles
sub logr() {
    my $msg = shift;
    for my $f (@LOGR_FILES) {
        if ($f eq *STDOUT) {
            if (length($msg) > 72) {
                print STDOUT wrap("", $SUB_TAB, $msg);
            } else {
                print STDOUT $msg;
            }
        } elsif ($f eq *STDERR) {
            if (length($msg) > 72) {
                print STDERR wrap("", $SUB_TAB, $msg);
            } else {
                print STDERR $msg;
            }
        } else {
            open F, ">> $f";
            if (length($msg) > 72) {
                print F wrap("", $SUB_TAB, $msg);
            } else {
                print F $msg;
            }
            close F;
        }
    }
    return;
}
sub usage_and_exit() {
        my $exitcode = shift;
        print <<_HELP_;

Usage: install.pl [-f] [-n] [-e] [-u] [-v] [-h]
    
    -n  --no_preserve   - disable preservation of old configs.
    -e  --exec_psad     - execute psad after installing.
    -u  --uninstall     - uninstall psad.
    -v  --verbose       - verbose mode.
    -h  --help          - prints this help message.

_HELP_
        exit $exitcode;
}
