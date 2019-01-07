#!/usr/bin/perl
#-------------------------------------------------------------------------------
#  $Id: infra.pl,v 1.124 2018/11/27 17:25:51 garykeller Exp $
#
#
#  This module contains the code that is executed on the
#  target server, usually by invocation via cron.
#
#-------------------------------------------------------------------------------
use IO::Socket;
use Benchmark;
use File::Path;
use File::Copy;

    my $TRUE        =         1;
    my $FALSE       =         0;

use Data::Dumper;

# Do NOT use the CVS $Revision tag here as it inserts an unusable string.
# Instead, note the version number above, and increment manually (above # + 1).
my $INFRA_VERSION = "1.105";


my $thisdir=`dirname $0`; chomp $thisdir;
my $rootdir=`cd $thisdir; pwd`; chomp $rootdir;

my @OBJECTS = ();
my %saw_obj = ();

my $host = `uname -n | cut -f 1 -d '.' `; chomp $host;
my $os = `uname -s`; chomp $os;

my $NSCONFS = "/web/suitespot/*/https-*/config/magnus.conf " .
                "/web/sunone/*/https-*/config/magnus.conf " .
                "/usr/local/gstapps/web/sunone/*/https-*/config/magnus.conf " .
                "/opt/iplanet/https-*/config/magnus.conf " .
                "/opt/iplanet61/https-*/config/magnus.conf" .
                "/gstapps/web/webserver7/https-*/magnus.conf" .
                "/web/webserver7/https-*/magnus.conf" ;

my $WLHOMES = "/weblogic/bea*/registry.xml " .
                "/weblogic/weblogic81/registry.xml " .
                "/apps/weblogic/bea*/registry.xml " .
                "/usr/local/gstapps/weblogic/bea*/registry.xml " .
                "/weblogic/registry.xml " .
                "/weblogic/weblogic81sp2/registry.xml " .
                "/projects/weblogic/installs/$host/bea1213/install/envVars.properties " ;

sub get_data {
    my $now = `date`; chomp $now;
    my $cpuspd = &get_cpu_speed( $os );
    # does not work everywhere: my $fqdn = `/usr/sbin/check-hostname | awk '{print \$NF}'`; chomp $fqdn;
    my $fqdn = `nslookup $host| grep "^Name:" | awk '{print \$2}'`; chomp $fqdn;
    my $os = `uname -s`; chomp $os;
    my $ver = `uname -r`; chomp $ver;
    my $type = &get_type;
    my $arch = `uname -m`; chomp $arch;
    my $env = `ls /GST-* | cut -f 2- -d '-' | tr '\n' ' ' `; chomp $env;
    my $plvl = &get_patch_level;
    my $ncpu = &get_num_cpu;
    my $mem = &get_mem;
    my $domain = &get_domain; chomp $domain;
    my $hardware = &get_hardware;


    my $data = "<infra version=\"$INFRA_VERSION\" " .
                            "localtime=\"" . $now . "\">\n";
    $data .= "<box name=\"$host\" environment=\"$env\" os=\"$os\" version=\"$ver\" " .
                    "fqdn=\"$fqdn\" " . " " .
                    "arch=\"$arch\" type=\"$type\" type2=\"$type2\" plvl=\"$plvl\" " .
                    "ncpu=\"$ncpu\" cpuspd=\"$cpuspd\" mem=\"$mem\" hardware=\"$hardware\" domain=\"$domain\" >\n";
            
    #WJO $data .= &get_sudo . "\n";
    $data .= &get_uptime . "\n";


    $data .= &port_scan . "\n";

    $data .= &routes . "\n";

    $data .= &established . "\n";
  
    $data .= &listeners . "\n";
  
    $data .= &get_autofs . "\n";

    $data .= &get_chkconfig . "\n";

    $data .= &get_crons( $os ) . "\n";

    $data .= &get_psus . "\n";

    $data .= &get_patches . "\n";
    
    $data .= &get_logins . "\n";

    $data .= &get_procmem . "\n";

    $data .= &get_vmlimit . "\n";

    $data .= &get_recent_files;
    
    if ($#OBJECTS > 0) {
        $data .= "<symbolobject>\n";
        for (@OBJECTS) {
            $data .=  &get_object($_);
            %saw_obj = ();
        }
        $data .= "</symbolobject>\n";
    }

    $data .= &unmounted . "\n";
    $data .=   &mounted . "\n";
    $data .=   &svcsx . "\n";
    $data .= &netgroups . "\n";

    #
    #  NB: run diskusage *after* the mounted/unmounted commands as this may force a mount!
    #
    my @df = &diskusage( $os );
    for (@df) { $data .= &format_tag("disk", $_) ."\n"; }

    my @ifs = &netifs;
    for (@ifs) { $data .= &format_tag("network", $_) ."\n"; }

    my @serv = &nsports($NSCONFS);
    for (@serv) { $data .= &format_tag_with_data("iplanet", $_) . "\n"; }

    my @homes = &wlhomes($WLHOMES);
    for (@homes) { $data .= $_; }

    $data .= "</box>\n";
    $data .= "</infra>\n";

    # Send USR1 signal to automountd to attempt cleanup
    system qq(/home/gstadmin/bin/sudo-l -k 2>/dev/null 1>&2);

    return $data;
}

####    This subroutine (send_data) is obsolete as now everything is 
####    mounted via /home/gstadmin
sub send_data {
    my $data = shift;
    my $sock = IO::Socket::INET->new(Proto => "tcp",
                                        PeerAddr => $INFRA_HOST,
                                        PeerPort => $INFRA_PORT);
    print $sock "POST /builds/infra/store.jsp HTTP/1.2\n";
    print $sock "Content-length: ", length $data, "\n";
    print $sock "Connection: close\n";
    print $sock "\n";
    print $sock $data;

    # get the response from the server
    while (<$sock>) { $rv .= $_; }

    # close the socket
    close $sock;

    return $rv;
}
###############################################################
###############################################################
sub get_object {
    my $obj = shift;
    my $retval = "  <object name=\"$obj\">\n";
    $retval .= &format_obj_links(&get_obj_links($obj));
    $retval .= "  </object>";
    return $retval;
}

sub format_obj_links {
    my $lnk = shift;
    my $retval = "";
    for (@$lnk) { $retval .= "    <link name=\"$_\">\n    </link>\n"; }
#    for (@$lnk) {
#        if (!$saw_obj{$_}) {
#            $saw_obj{$_} = 1;
#            $retval .= "<link name=\"$_\">\n";
#            #$retval .= &format_obj_symbols(&get_obj_symbols($_));
#            $retval .= &format_obj_links(&get_obj_links($_));
#            $retval .= "</link>\n";
#        }
#   }
    return $retval;
}

sub format_obj_symbols {
    my $sym = shift;
    for (@$sym) { $retval .= "<symbol name=\"$_\"/>\n"; }
    return $retval;
}

sub get_obj_links {
    my $obj = shift;
    my @linf = `ldd $obj`;
    my @l = ();
    for (@linf) {
        chomp;
        my($w, $l, $p, $lp) = split /\s+/;
        if ($lp =~ /^\//) {
            push @l, $lp if ($lp);
        }
    }
    return \@l;
}

sub get_obj_symbols {
    my $lib = shift;
    my @sinf = `nm -Cgp $lib`;
    my @f = ();
    for (@sinf) {
        chomp;
        my($n, $m, $f) = split /\s+/;
        push @f, $f if ($f);
    }
    @f = sort @f;
    return \@f;
}

#WJO: there are files under /etc/*release that have some patching info not going to fix that at this point
sub get_patches {
    my $retval = "";
    my $dir = "/var/sadm/patch";
    my @patches = qw();
    if( -d $dir ) {
        @patches = `ls -1 $dir`;
    } else {
        push @patches, "$dir: does not exist";
    }
    for (@patches) {
        chomp;
        $retval .= "<patch name=\"$_\"/>\n";
    }
    return $retval;
}

sub get_psus {
    my $psout = `/home/gstadmin/bin/psus -a`;
    my $pshog = `/home/gstadmin/bin/pshog`;
    my $pstym = `/home/gstadmin/bin/pstime -a`;
    my $ptree = `/bin/ptree -a`;
    my $prsta = `/bin/prstat -a -s rss 1 1`;

    my $data = $data . "<ps_data>\n" ;
       $data = $data . "<ps_out>\n<![CDATA[\n" . $psout . "\n]]>\n</ps_out>\n" ;
       $data = $data . "<ps_hog>\n<![CDATA[\n" . $pshog . "\n]]>\n</ps_hog>\n" ;
       $data = $data . "<ps_time>\n<![CDATA[\n" . $pstym . "\n]]>\n</ps_time>\n" ;
       $data = $data . "<ps_tree>\n<![CDATA[\n" . $ptree . "\n]]>\n</ps_tree>\n" ;
       $data = $data . "<ps_stat>\n<![CDATA[\n" . $prsta . "\n]]>\n</ps_stat>\n" ;
       $data = $data . "</ps_data>\n" ; 
    return $data;
}

sub get_autofs {
    my $ad = `test -f /etc/auto_direct && cat /etc/auto_direct`; chomp $ad;
    my $ah = `test -f /etc/auto_home && cat /etc/auto_home`; chomp $ah;
    my $am = `test -f /etc/auto_mnt && cat /etc/auto_mnt`; chomp $am;

    my $data = "<auto_direct><![CDATA[" . $ad . "]]></auto_direct>\n" .
                "<auto_home><![CDATA[" . $ah . "]]></auto_home>\n" .
                "<auto_mnt><![CDATA[" . $am . "]]></auto_mnt>\n";
    return $data;
}

sub get_chkconfig {
    if ($os =~ m/Linux/) {
	my $cfg = `test -x /sbin/chkconfig && /sbin/chkconfig`; chomp $cfg;
	my $data = "<chkconfig>\n <![CDATA[\n" . $cfg . "\n]]>\n</chkconfig>\n";
	return $data;
    }
}

sub get_procmem {
    my $procm = `/home/gstadmin/bin/procmem`; chomp $procm;
    my $data = "<procmem><![CDATA[" . $procm . "]]></procmem>\n";
    return $data;
}

sub get_vmlimit {
    my $vmlimit = `/home/gstadmin/bin/vmlimit`; chomp $vmlimit;
    my $data = "<vmlimit><![CDATA[" . $vmlimit . "]]></vmlimit>\n";
    return $data;
}

sub get_sudo {
    my $sudofile;
    my $system_datadir = "/home/gstadmin/cvswork/gstadmin/infrastructure/system_data/$host";
    my $sdata = "<sudo_file> <![CDATA[\n";
    if (-T "/usr/local/etc/sudoers") {
        $sudofile = `cat /usr/local/etc/sudoers`; chomp $sudofile;
        # populate the system_data directory, too
        system qq(/bin/cp -p /usr/local/etc/sudoers /tmp/sudoers);
        system qq(/bin/chmod 777 /tmp/sudoers);
        system qq(/bin/su - gstadmin -c "/bin/cp -p /tmp/sudoers $system_datadir/usr/local/etc/sudoers");
        system qq(/bin/rm -f /tmp/sudoers);
    }
    if (-T "/opt/local/etc/sudoers") {
        $sudofile = `cat /opt/local/etc/sudoers`; chomp $sudofile;
        ### todo: populate system_data dir with this, too??
    }
    $sdata = $sdata . $sudofile . "\n]]></sudo_file>\n";
    return $sdata;
}

sub get_crons {
    my $os = shift;
    my $data;
    my %users;

    # Solaris might use /var/spool/cron/crontabs as the parent dir
    # Linux   might use /var/spool/cron          as the parent dir
    my $crondir = qw();
    my $lnx_cron_dir = "/var/spool/cron";
    my $unix_cron_dir = "/var/spool/cron/crontabs";
    
    if( &is_os_lnx( $os ) ) {
        $crondir = $lnx_cron_dir;
    } else {
        $crondir = $unix_cron_dir;
    }

    if (-d $crondir and -r $crondir) {
        # if just a file, return empty
        if ( -f $crondir ){
            return "$crondir is file not directory";
        }
    } else {
        return "unable to read: $crondir";
    }



    my @crons = `ls -1 $crondir | grep -v '\\.'`;
    for (@crons) {
        chomp;
        if (-T "$crondir/$_") {
            my $u = $_;
            #- das:  my @data = `egrep -v "^#" $crondir/$u 2>/dev/null`;
            my @data = `cat $crondir/$u 2>/dev/null`;
            for (@data) {
                $users{$u} .= "<job type=\"cron\">" .
                                "<![CDATA[" . $_ . "]]></job>\n";
            }
        }
    }

    my @ats = `ls -1 /var/spool/cron/atjobs 2>/dev/null`;
    for (@ats) {
        chomp;
        if (-T "/var/spool/cron/atjobs/$_") {
            my $u = $_;
            my @data = `egrep -v "^#" /var/spool/cron/atjobs/$u 2>/dev/null`;
            for (@data) {
                $users{$u} .= "<job type=\"at\">" .
                                "<![CDATA[" . $_ . "]]></job>\n";
            }
        }
    }

    for (keys %users) {
        $data .= "<cron user=\"" . $_ . "\">\n" . $users{$_} . "</cron>\n";
    }

    return $data;
}

sub port_scan {
    my $data;
    my @ports = "";
    my %procport = ();

    if ($os =~ m/SunOS/) {
        @ports = `netstat -an | grep "LISTEN" | awk '{print \$1}' | awk 'BEGIN { FS = "." }   { print \$NF }' | sort -n | uniq`;
    }
    else {
        @ports = `netstat -an | grep LISTEN | tr -s " " | tr " " ":" |cut -d":" -f 5 | grep [0-9] | sort -n | uniq`;
    }

    #WJO tail +2 will skip the first line however this option does not work in Linux. 
    #    However because I am a scripting god I am using the awk option NR>1 which will work on both OSs
    # my @procs = `ps | awk '{print \$1}' | tail +2 | xargs pfiles 2> /dev/null | egrep "(^[0-9])|(sockname.*port)"`;
    my @procs = `ps | awk 'NR>1 {print \$1}' | xargs pfiles 2> /dev/null | egrep "(^[0-9])|(sockname.*port)"`;

    my $procname = "";
    my $portnum = 0;
    for (@procs) {
        shift;
        chomp;
        if (/^[0-9]*:\s*(.*)$/){
            $procname = $1; 
        }
        elsif(/\s*.*port:\s*([0-9]*).*$/){          
            $portnum = $1;
            $procport{$portnum} = $procname;
        }
    }
    
    for (@ports) {
        chomp;
       
        $app = &get_port_application($_);
        if ($app eq "Unknown") {
            foreach $key (keys %procport){
                if ($key == $_){ 
                
                $app = $procport{$key};
                print "$app is on port $key \n";
                }
            }
        }
        $data .= "<port number=\"$_\" app=\"" .
                 $app . "\"/>\n";
        
    }
 #   for (my $i=1; $i <= 65535; $i++) {
 #      if (&check_port('127.0.0.1', $i)) {
 #           $data .= "<port number=\"$i\" app=\"" .
 #                       &get_port_application($i) . "\"/>\n";
 #       }
 #   }
    return $data;
}

sub routes {
    my $routes = `netstat -rn`;
    chomp $routes;
    return "<route>\n<![CDATA[\n" .  $routes .  "\n]]>\n</route>\n";
}

sub established {
    my $ports = `netstat -an | grep "ESTABLISHED" | sort -n | uniq`;
    chomp $ports;
    return "<established>\n<![CDATA[\n" .  $ports .  "\n]]>\n</established>\n";
}

sub listeners {
    my $ports = `netstat -an | grep "LISTEN" | sort -n | uniq`;
    chomp $ports;
    return "<listeners>\n<![CDATA[\n" .  $ports .  "\n]]>\n</listeners>\n";
}

sub get_type {
    my $type = `/usr/sbin/prtconf -pv 2>/dev/null | grep banner-name | cut -f 2 -d "'" `;
    chomp $type;
    if ($type eq "") {
        $type = `uname -i`;
        $type =~ s/SUNW,//;
        chomp $type;
    }

    # For some odd cases...
    # Remove the (TM) string;  split into two lines at the '('
    $type =~ s,\(TM\) ,,;
    ($type, $type2) = split(/\(/, $type, 2);
    $type2 = '(' . $type2 if $type2;
    return $type;
}

sub get_patch_level {
    my $plvl = `uname -v`; chomp $plvl;
    $plvl =~ s/^.+_(.+)\s*$/$1/;
    return $plvl;
}

sub get_uptime {
    my $ut = `uptime`; chomp $ut;
    # Sometimes on recently-booted servers, there is no "up" string...
    if ($ut !~ /up/) {
       $ut =~ s,^ *,,;
       my ($time) = split(/\s+/, $ut);
       return "<uptime time=\"$time\" up=\"unknown!\"/>";
    };

    $ut =~ /^\s*(.+)\s+up\s+(.+?)[,]\s+(.+?)[,].+$/i;
    return "<uptime time=\"$1\" up=\"$2, $3\"/>";
}

#WJO 17 March 2016 the libraries being used kstat are no longer supported by current versions of perl
#there are ugly hacks to make it work but I am going to use other commands to duplicate functionality
sub get_cpu_speed {
    my $os = shift;
    my $cpuspd = "unknown";

    if( &is_os_lnx( $os ) ){
        my $cmd = "/usr/bin/lscpu";
        if( -x $cmd ) {
            $cpuspd = `$cmd`;
        # Match: CPU MHz:               2497.108
            $cpuspd =~ s/.*CPU\s+(.Hz):\s+([0-9\.]+).*/$2 $1/is;
        } else {
           $cpuspd = `grep "cpu MHz" /proc/cpuinfo | uniq`;
          # Match: cpu MHz         : 2600.000
           $cpuspd =~ s/.*cpu\s+(.Hz)\s+:\s+([0-9\.]+).*/$2 $1/is;
        }
    } else {
        #Assume: All machines will have at least one processor and all processors will have same speed

        my $cmd = "/usr/sbin/psrinfo";
        my $opts = " -v -p 0";
        my $opts_v2 = " -v";
        my $parse_succes = $FALSE;
        if( -x $cmd ) {
            my $cpuspd_txt = `$cmd $opts`;
            #Match: sun4v-cpu (chipid 0, clock 2848 MHz)
            if( $cpuspd_txt =~ /.*clock\s+([0-9\.]+\s+.Hz)\).*/is ) {
                $cpuspd = $1;
                $parse_succes = $TRUE;
            } else {
                $parse_succes = $FALSE;
                $cpuspd_txt = `$cmd $opts_v2`;
                my @junk = split /Status\s+/i, $cpuspd_txt;
                $cpuspd_txt = $junk[1];
            }
            if( $parse_succes ){
                #nothing to do
            } elsif( $cpuspd_txt =~ /.*at\s+([0-9\.]+\s+.Hz).*/is ) {
                #The sparcv9 processor operates at 1503 MHz
                $cpuspd = $1;
            } else {
                $cpuspd = "$cmd: Parse Has Failed";
            } 
        } else {
            $cpuspd = "Unable to execute: $cmd";
        }
    }
    return $cpuspd;
}

sub get_domain {
    return `ypwhich 2>/dev/null || echo ldap`;
}

sub get_mem {
    if( -x "/usr/sbin/prtconf" ) {
        $mem = `/usr/sbin/prtconf 2>/dev/null | egrep -i "memory[ ]+size" | sed 's,Megabytes,MB,' | cut -f 2 -d :`;
        chomp $mem;
#       $mem =~ s/\SGB/ GB/;
    } elsif( -r "/proc/meminfo" ) {
        $mem = `cat /proc/meminfo | grep MemTotal: | cut -f 2 -d :`;
        chomp $mem;
    }
    $mem =~ s/^\s+//;
    return $mem;
}
sub get_num_cpu {
    my ($virtcpu, $totalcpu) = qw();
    
    my $unixCpuCmd = "/usr/sbin/psrinfo";
    my $unixCpuCmdOpt = "-pv";
    my $unixZoneCmd = "prctl -n zone.cpu-shares -i zone";
    my $unixZoneNameCmd = "/usr/sbin/zoneadm";
   
    my $linuxCfgFile = "/proc/cpuinfo";
    #print "Lnx Cfg File: $linuxCfgFile: ". -s $linuxCfgFile;

    #psrinfo -vp will give me both total number of CPUs and Speed
    if( -x $unixCpuCmd ) {
         my $cmd = "$unixCpuCmd $unixCpuCmdOpt";
         my $ret_val = `$cmd`;
         #print "Run Cmd: $cmd Return: $ret_val";
         ($totalcpu) = $ret_val =~ /.*physical processor has\s+(\d+)\s+.*/is;
         #print "CPU Count: $totalcpu\n";

         #system is a zone and may not have all CPU assigned
         if( -x $unixZoneNameCmd ) {
             $cmd = $unixZoneCmd . " ".  `/usr/sbin/zoneadm list`;
             $ret_val = `$cmd`;
             #print "Run Cmd: $cmd Return: $ret_val\n";
             ($virtcpu) = $ret_val =~ /.*privileged\s+(\d+)\s+.*/is;
         } else {
             $virtcpu = $totalcpu;
         }
     } elsif( -e $linuxCfgFile ) {
         open FILE, $linuxCfgFile or die "Couldn't open file $linuxCfgFile : $!"; 
         my $ret_val = join("", <FILE>); 
         close FILE;

         #print "Read File: $linuxCfgFile text: $ret_val\n";
         my ($count) = $ret_val =~ /.*processor\s+:\s+(\d+)\s*/is;
         $totalcpu = $count + 1;
         $virtcpu = $totalcpu;
         #print "CPU Count: $count\n";
     } else {
         print "CPU info gather failed - no known process\n";
     }
     return $virtcpu . "/" . $totalcpu;
}
#sub get_num_cpu {
#    # physical on system
#    my $pcpu = `uname -X | grep -i numcpu`; 
#    $pcpu =~ s/^\s*numcpu\s+[=]\s+(.+)$/$1/i;
#    chomp $pcpu;
#    if ($pcpu == "") {
#        $pcpu = `nproc`;
#        chomp $pcpu;
#    }
#    my $ncpu = $pcpu;
#
#    # For new virtual zones, there may be shared cpus.  This may be more accurate.
#    if (-f "/usr/sbin/zoneadm") {
#        my $zone = `/usr/sbin/zoneadm list`; chomp $zone;
#        $ncpu = `prctl -n zone.cpu-shares -i zone $zone | grep priv | awk '{print \$2}'`;
#    }
#    chomp $ncpu;
#    return $ncpu . "/" . $pcpu;
#}

sub get_hardware {
    my $hardware = `test -f /etc/hardwarename && cat /etc/hardwarename | cut -f 1 -d '.' `;
    chomp $hardware;
    return $hardware;
}

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

sub get_logins {
    my $retval = "<logins>\n";
    if ($os =~ m/SunOS/) {
        my @syslogins = `logins -os`; chomp (@syslogins);
        for (@syslogins) {
            my @vals = split /:/, $_, 5;
            $retval .= "<syslogin login=\"$vals[0]\" uid=\"$vals[1]\" group=\"$vals[2]\" gid=\"$vals[3]\" name=\"$vals[4]\" />\n";
        }
    }

    if ($os =~ m/Linux/) {
        my @syslogins = `cat /etc/passwd | grep -v "^-" | grep -v "^+" | sort -t: -k 3n,3` ; chomp (@syslogins);
        for (@syslogins) {
            my @vals = split /:/, $_;
            my $groupname = `getent group | grep ":$vals[3]:" | cut -d":" -f 1` ; chomp $groupname;
            $vals[4] =~ tr/"//d;
            $retval .= "<syslogin login=\"$vals[0]\" uid=\"$vals[2]\" group=\"$groupname\" gid=\"$vals[3]\" name=\"$vals[4]\" />\n";
        }
    }
    
    if ($os =~ m/SunOS/) {
        my @userlogins = `logins -otu`; chomp (@userlogins);
        for (@userlogins) {
            my @vals = split /:/, $_, 5;
            $retval .= "<userlogin login=\"$vals[0]\" uid=\"$vals[1]\" group=\"$vals[2]\" gid=\"$vals[3]\" name=\"$vals[4]\" />\n";
        }
    }

    if ($os =~ m/Linux/) {
        my @Passwd_Groups = `cat /etc/passwd | grep ^+ | tr -d "+" | cut -d ":" -f1`; chomp @Passwd_Groups;
        my @Netgroups = `cat /etc/security/access.conf | grep ^+ | cut -d ":" -f2`; chomp (@Netgroups);
        push (@Netgroups, @Passwd_Groups);
        my @users = ();
        my @group = ();
        for (@Netgroups) {
            if ( $_ =~ m/@/ ) {
                $_ =~ s/@//;
                $_ =~ s/\s+$//;
                @group = `test -x /admin/arch/bin/netgroupcat && /admin/arch/bin/netgroupcat $_ | cut -d "," -f2 | grep -v "\-"`; 
                chomp @group;
                push (@users, @group);
            }
            else {
                $_ =~ s/^\s+//;
                $_ =~ s/\s+$//;
	        @group = split(' ',$_);
                foreach my $val (@group) {
                    push (@users, "$val");
                }
            }
        }
    
        my @sorted_users = uniq sort @users; chomp (@sorted_users);
        for (@sorted_users) {
            my $user = `getent passwd $_`; chomp $user;
            if ($user eq "") {
                next
            }
            my @vals = split /:/, $user;
            my $groupname = `getent group | grep ":$vals[3]:" | cut -d":" -f 1`; chomp $groupname;
            $vals[4] =~ tr/"//d;
            $retval .= "<userlogin login=\"$vals[0]\" uid=\"$vals[2]\" group=\"$groupname\" gid=\"$vals[3]\" name=\"$vals[4]\" />\n";
        }
    }
    
    $retval .= "</logins>";

    return $retval;
}

sub get_recent_files {
    my $retval = "";
    my @files = `test -d /home/gstadmin/cvswork/gstadmin/infrastructure/system_data/${host} && find /home/gstadmin/cvswork/gstadmin/infrastructure/system_data/${host} -mtime -7 | grep -v CVS`;
    for (@files) {
        chomp;
              ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
                $atime,$mtime,$ctime,$blksize,$blocks)
                = stat("$_");

        my $humantime = scalar localtime $mtime;

        my @realnames = split /\//, $_, 9;
        my $realname = "/" . $realnames[8];
        $retval .= "<modified name=\"$realname\" time=\"$humantime\" />\n";
    }
    return $retval;
}

sub prtdiag {
    my $pd = `/usr/platform/sun4u/sbin/prtdiag -v`; chomp $pd;
    return "<hardware>\n<![CDATA[\n" .  $pd .  "\n]]>\n</hardware>\n";
}

###
# output for svcs -x command
###
sub svcsx {
    my $rv;
    my $out = `test -x /bin/svcs \&\& /bin/svcs -x`; chomp $out;
    my @rows = split /\n|\r/, $out;
    for (my $i=0; $rows[$i]; $i++) {
        my $row =  "<svcs-x> " . "$rows[$i]" . " </svcs-x>\n";
        $rv .= $row;
    }
    return $rv;
}

###
# output for /etc/passwd netgroups data
###
sub netgroups {
    my $rv;
    my $out = `/bin/grep '^+' /etc/passwd  | cut -f 2 -d '\@' | cut -f 1 -d ':' `; chomp $out;
    my @rows = split /\n|\r/, $out;
    for (my $i=0; $rows[$i]; $i++) {
        my $row =  "<netgroup> " . "$rows[$i]" . " </netgroup>\n";
        $rv .= $row;
    }
    return $rv;
}

###
# output for unmounted command
###
sub unmounted {
    my $rv;
    my $out = `/home/gstadmin/bin/unmounted -a`; chomp $out;
    my @rows = split /\n|\r/, $out;
    for (my $i=0; $rows[$i]; $i++) {
        my $row =  "<unmounted> " . "$rows[$i]" . " </unmounted>\n";
        $rv .= $row;
    }
    return $rv;
}

###
# simple output for mounted command -- should be xml format
###
sub mounted {
    my $rv;
    my $out = `/home/gstadmin/bin/mounted -a`; chomp $out;
    my @rows = split /\n|\r/, $out;
    for (my $i=0; $rows[$i]; $i++) {
        my $row =  "<mounted> " . "$rows[$i]" . " </mounted>\n";
        $rv .= $row;
    }

    # Now, get the mounted info with a timestamp
    $out = `/home/gstadmin/bin/mounted -t`; chomp $out;
    @rows = split /\n|\r/, $out;
    for (my $i=0; $rows[$i]; $i++) {
        my $row =  "<mounted-t> " . "$rows[$i]" . " </mounted-t>\n";
        $rv .= $row;
    }

    return $rv;
}
sub is_os_lnx {
    my $os = shift;
    my $is_lnx = $FALSE;
     if( $os =~ /linux/i ){
        $is_lnx = $TRUE;
    }
    $is_lnx;
}
sub get_perl {
    my $os = shift;
    my $root = "/gstdev/perl-5.22.1";

    if( &is_os_lnx( $os ) ){
        $root .= "_lnx";
    }
    my $env = "PERL5LIB=$root/lib/5.22.1; $root/bin/perl";
    return $env;
}
### 
# get disk usage
# returns a list of hash refs
###
sub diskusage {
    my $os = shift;
    my $gstdev = "/gstdev/perl-5.22.1";
    my @df = qw();
    # Ensure this runs in Linux, too
    system("/home/gstadmin/bin/mountcheck 2>/dev/null");
    if ($os =~ m/SunOS/ && -d $gstdev ) {
	@df = &diskusage_SunOS ($os) ;
    }
    elsif ($os =~ m/Linux/) {
	@df = &diskusage_Linux;
    }
# Not SunOS or Linux, so go old school...
    else {
        print "Going old school df -k for this host!\n";
        @df = &diskusage_old ($os);
    }

    return @df;
}

### 
# get disk usage
# returns a list of hash refs
###
sub diskusage_SunOS {
    my $os = $_[0];

    my $perl_env = &get_perl( $os );
    my $df = `$perl_env /home/gstadmin/bin/df_dash_k`;

    my @dftxt = split /\n|\r/, $df;
    my @headings = split /\s+/, $dftxt[0];
    for (@headings) { s/ /_/g; }
    for (my $i=1; $dftxt[$i]; $i++) {
        my %df = ();
        $df{units} = "kbytes";

        my @parts = split /\s+/, $dftxt[$i];
        for (my $j=0; $headings[$j]; $j++) {
            $df{$headings[$j]} = $parts[$j];
        }

        push @df, \%df;
    }
    return @df;
}

sub diskusage_Linux {
    my $df = `df -TPk | sed -e 's/Use%/capacity/' -e 's/Capacity/capacity/' -e 's/1K-blocks/kbytes/' -e 's/1024-blocks/kbytes/' -e 's/Available/avail/' -e 's/Used/used/'`; chomp $df;

    my @dftxt = split /\n|\r/, $df;
    my @headings = split /\s+/, $dftxt[0], 7;
    for (@headings) { s/ /_/g; }
    for (my $i=1; $dftxt[$i]; $i++) {
        my %df = ();
        $df{units} = "kbytes";

        my @parts = split /\s+/, $dftxt[$i];
        for (my $j=0; $headings[$j]; $j++) {
            $df{$headings[$j]} = $parts[$j];
        }

        push @df, \%df;
    }
    return @df;
}

sub diskusage_old {
    my $os = $_[0];

    my @df = ();
    # Ensure this runs in Linux, too
    system("/home/gstadmin/bin/mountcheck 2>/dev/null");
    my $df = `df -k | sed -e 's/Use%/capacity/' -e 's/Capacity/capacity/' -e 's/1K-blocks/kbytes/' -e 's/1024-blocks/kbytes/' -e 's/Available/avail/' -e 's/Used/used/'`; chomp $df;

    my @alldf = split /\n|\r/, $df;
    my @headings = split /\s+/, $alldf[0], 6;
    for (@headings) { s/ /_/g; }
    for (my $i=1; $alldf[$i]; $i++) {
        my %df = ();
        $df{units} = "kbytes";

        my @parts = split /\s+/, $alldf[$i];
        for (my $j=0; $headings[$j]; $j++) {
            $df{$headings[$j]} = $parts[$j];
        }

        push @df, \%df;
    }

    return @df;
}

###
# get network interfaces
# returns a list of hash refs
###
sub netifs {
    my @ifs = ();
    #
    # NOTE: new systems may find two ':' chars, so change the ": " to "@ " for
    #       parsing accurately
    #
    if ($os =~ m/SunOS/) {
        my $ifs = `/sbin/ifconfig -a | sed 's/: /@ /1'`; chomp $ifs;
        my @allif = split /^([a-z0-9:]+)[@]/im, $ifs;
        for (my $i=0; $allif[$i+1]; $i++) {
            next if ($allif[$i] =~ /^$/);

            my %ifs = ();

            $ifs{interface} = $allif[$i];

            $allif[$i+1] =~ s/[\n\r]//g;
            $allif[$i+1] =~ s/^\s*//g;
            my @parts = split /\s+/, $allif[++$i];
            $parts[0] =~ s/\s*flags\=(.+?)[<](.+?)[>]/$1\[$2\]/;
            $ifs{flags} = $parts[0];

            for (my $j=1; $parts[$j+1]; $j+=2) {
                chomp $parts[$j]; chomp $parts[$j+1];
                $ifs{$parts[$j]} = $parts[$j+1];
            }

            next if ($ifs{flags} =~ /[:]/);

            push @ifs, \%ifs;
        }
    }

    if ($os =~ m/Linux/) {
        my $ifs = `/sbin/ifconfig -a | egrep '(Link encap:)|(inet addr:)|(MTU:)'`; chomp $ifs;
        my @allif = split /\n/, $ifs;
        my $num = scalar @allif;
        for (my $i=0; $i <= $num; $i += 3) {

            my %ifs = ();
            my @parts1 = ();
            my @parts2 = ();

            if ($allif[$i+1] !~ m/inet addr:/) {
                --$i;
                next;
            }

            $ifs{interface} = `echo $allif[$i] | cut -d " " -f1`;
            chomp $ifs{interface};
            $allif[$i+1] =~ s/^\s*//g;
            $allif[$i+1] =~ s/inet addr:/inet /;
            $allif[$i+1] =~ s/Bcast:/broadcast /;
            $allif[$i+1] =~ s/Mask:/netmask /;
            @parts1 = split /\s+/, $allif[$i+1];
            for (my $j=0; $parts1[$j+1]; $j+=2) {
                chomp $parts1[$j]; chomp $parts1[$j+1];
                $ifs{$parts1[$j]} = $parts1[$j+1];
            }

            $allif[$i+2] =~ s/^\s*//g;
            $allif[$i+2] =~ s/ /,/g;
            $allif[$i+2] =~ s/:/ /g;
            $allif[$i+2] =~ s/,,/ /g;
            $allif[$i+2] =~ s/MTU/mtu/;
            $allif[$i+2] =~ s/Metric/metric/;
            @parts2 = split /\s+/, $allif[$i+2];
            $parts2[0] = "\[$parts2[0]\]";
            $ifs{flags} = $parts2[0];

            for (my $j=1; $parts2[$j+1]; $j+=2) {
                chomp $parts2[$j]; chomp $parts2[$j+1];
                $ifs{$parts2[$j]} = $parts2[$j+1];
            }

            push @ifs, \%ifs;
        }
    }

    return @ifs;
}


### 
# get iplanet sso configs
# pass obj.conf file path
# returns xml data
###
sub nsssoconfs {
    my $config = shift;
    my $data;
    open CF, "<$config"; my @lines = <CF>; close CF;
    my $file = join '', @lines;
    my @sso = $file =~ /^\s*\<Object\s+(.+)\>\s+Service\s+(.*\s*fn=\"{0,1}wl[-_]proxy\"{0,1}.*)\s+<\/Object>\s*$/gm;
    for (@sso) {
        my $attr = &clean_tag($_);
        if ($$attr{'fn'} =~ /wl[-_]proxy/) {
            $data .= "<Service";
            for (keys %$attr) { $data .= " " . $_ . "=\"" . $$attr{$_} . "\""; }
            $data .= "/>\n</sso>\n";
        }
        else {
            $data .= "<sso";
            for (keys %$attr) { $data .= " " . $_ . "=\"" . $$attr{$_} . "\""; }
            $data .= ">\n";
        }
    }
    return $data;
}

### 
# get iplanet attributes
# pass magnus.conf file path(s)
# returns a list of hash refs
###
sub nsports {
    my @server = ();
    my $configs = shift;
    my $confs = `ls $configs 2>/dev/null`;
    my(@confs) = split /\n|\r/, $confs;
    for (@confs) {
        chomp;
        my $cf = `dirname $_`; chomp $cf;
        my %det = ();
        open CF, "<$_";
        while (<CF>) {
            chomp;
            if (!/^\#/) {
                my($k, $v) = split /\s/, $_, 2;
                if (($k eq "Port") || ($k eq "ServerID")) {
                    $det{$k} = $v;
                }
            }
        }
        close CF;


        if (!$det{'Port'}) {
            open CF, "<$cf/server.xml";
            my $incomment = false;
            while (<CF>) {
                my $line = $_;
                if( $line =~ /<!--/ ){
                    $incomment = true;
                }
                if( $line =~ /-->/ ){
                    $incomment = false;
                }
                if( $incomment =~/false/ && 
                    $line =~ /.+\s+port\s*=\s*[\"]?(\d+)[\"]?\s*.*$/ ){
                    my $portnum = $1;
                    if ($portnum) { $det{'Port'} = $portnum; }
                }
            }
            close CF;
        }

        my $data = &nsssoconfs($cf . "/obj.conf");
        $det{'_DATA_'} = $data;

        push @server, \%det;
    }
    return @server;
}

sub wlconfig {
    my @server = ();
    my $configs = shift;
    #print "New config---------------------------\n";
    #print $configs . "\n";
    #print "---------------------------\n";
    my $confs = `ls $configs 2>/dev/null`;
    my(@confs) = split /\n|\r/, $confs;
    for (@confs) {
        chomp;
        #print $_ . "\n";
        my $data = `cat $_ | grep -v "<\?xml "`;
        push @server, $data;
    }
    return @server;
}

sub wlhomes {
    my @home = ();
    my $homes = shift;
    my $h = `ls $homes 2>/dev/null`;
    my @homes = split (/\n|\r/, $h);
    for (@homes) {
        my @serv = ();
        my $home = `dirname $_`; chomp $home;
        my $symb = "";
        my $data = "";
        my $p = 0;
        #print "New home---------------------------\n";
        #print "$_" . "\n";
        #print "---------------------------\n";
        open REG, "<$_";
        while (<REG>) {
            if (/<\s*bea-product-information.*>/i) {
                $p = 1;
            }
            elsif (/JavaHome\s*=\s*\"(.+?)\"/) {
                my $tmpline = $_;

                my $jre = $1 . "/jre/lib/sparc/libjava.so";
                if (-f $jre) {
                    $symb = "\n<symbolobjects>\n" .
                            &get_object($jre) .
                            "\n</symbolobjects>\n";
                    %saw_obj = ();
                }

                if ($tmpline =~ /InstallDir\s*=\s*\"(.+?)\"/) {
                    @serv = &wlconfig($1 . "/config/*/config.xml " .
                                      $1 . "/user_projects/*/config.xml " .
                                      $1 . "/user_projects/*/*/config.xml " .
                                      $1 . "/user_projects/*/*/*/config.xml " .
                                      $1 . "/../user_projects/domains/*/config.xml " .
                                      "/weblogic/user_projects/domains/*/config.xml" );
                }
            }
            elsif (/InstallDir\s*=\s*\"(.+?)\"/) {
                #print $1 . "\n";           
                @serv = &wlconfig($1 . "/config/*/config.xml " .
                                  $1 . "/user_projects/*/*/*/config.xml " .
                                  $1 . "/user_projects/*/*/config.xml " .
                                  $1 . "/user_projects/*/config.xml");
            }
            elsif (/<\s*\/\s*bea-product-information\s*>/i) {
                my $lic = `cat $home/license.bea 2>/dev/null | grep -v "<\?xml "`;
                $data .= $lic . "\n";
                for (@serv) { 
                    $data .= $_; 
                }
                $data .= $symb;
                $data .= $_;
                $p = 0;
            }
            elsif (/JAVA_HOME_CCR=(.+?)/) {
                chomp;
                my $tmpline = $_;
                my @javadir = split /=/, $_;
                my $jre = "$javadir[1]" . "/jre/lib/amd64/libjava.so";
                if (-f $jre) {
                    $symb = "\n<symbolobjects>\n" .
                            &get_object($jre) .
                            "\n</symbolobjects>\n";
                    %saw_obj = ();
                }
                @serv = &wlconfig("/projects/weblogic/user_projects/$host/[DSP]*/config/config.xml");
                for (@serv) {
                    $data .= $_;
                }
                $data .= $symb;
            }

            $data .= $_ if ($p);
        }
        close REG;
        push @home, $data;
    }
    return @home;
}

sub get_port_application {
    my $port = shift;
    return &get_service($port);
}

###
# check if something is listening on a port
# pass ip and port
# returns 0 on failure (nothing is currently listening), 1 on success (connected to port)
###

sub check_port {
    my $remote = shift;
    my $port = shift;
    my $tmp = IO::Socket::INET->new(Proto => "tcp",
                                    PeerAddr => $remote,
                                    PeerPort => $port,
                                    Timeout => 1) || return 0;
    close $tmp;
    return 1;
}

###
# format an xml tag
# pass tag name and hash ref of attributes
# returns the formatted xml string
###
sub format_tag_with_data {
    my $tag = shift;
    my $attr = shift;
    my $data;
    my $rv = "<$tag";
    for (keys %$attr) {
        if ($_ eq "_DATA_") { $data = $$attr{$_}; }
        else { $rv .= " $_=\"$$attr{$_}\""; }
    }
    if ($data) { $rv .= ">\n" . $data . "\n" . "</$tag>"; }
    else { $rv .= "/>"; }
    return $rv;
}

###
# format an xml tag
# pass tag name and hash ref of attributes
# returns the formatted xml string
###
sub format_tag {
    my $tag = shift;
    my $attr = shift;
    my $rv = "<$tag";
    for (keys %$attr) { $rv .= " $_=\"$$attr{$_}\""; }
    $rv .= "/>";
    return $rv;
}

sub trim()
{
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

sub clean_tag {
    my $tag = shift;
    my %attr = ();
    my @attr = split /\s+/, $tag;
    for (@attr) {
        my($k, $v) = split /=/;
        $k =~ s/^\s*(.+)\s*$/$1/;
        $v =~ s/^\s*\"{0,1}(.+?)\"{0,1}\s*$/$1/;
        if ($k && $v) {
            if ($k =~ /[A-Za-z0-9_-]/) { $attr{$k} = $v; }
        }
    }
    return \%attr;
}

sub get_service {

    my $p = shift;
    open SVS, "</etc/services";
    my @svs = <SVS>;
    close SVS;
    for (@svs) {
        if (!/^\s*#/) {
            chomp;
            my($name, $port_prot, @data) = split /\s+/;
            my($port, $prot) = split /\//, $port_prot;
            if ($port eq $p) { return $name; }
        }
    }

    return "Unknown";
}

sub save_data {
    my $data = shift;

    my $ip_dot = `nslookup $host| grep "^Address:" | tail -1 | awk '{print \$2}'`; 
    chomp $ip_dot;
    my $ip = `nslookup $host| grep "^Address:" | tail -1 | awk '{print \$2}' | tr '.' '_'`; 
    chomp $ip;

    # If IP is not know via nslookup, pick it out of ifconfig.
    if ( $ip eq '' ) 
    {
        $ip =`/sbin/ifconfig -a | tail -1 | cut -d ' ' -f2 | tr '.' '_'`;
        chomp $ip;
        $ip_dot =`/sbin/ifconfig -a | tail -1 | cut -d ' ' -f2`;
        chomp $ip_dot;
    }

    my $datadir = `grep DATA_DIR ${rootdir}/web/root.jsp | cut -f 2 -d '"' `;
    chomp $datadir;
    if ($ARGV[0] eq "-l") {
        $datadir = $ARGV[1];
    }
    ###print "$datadir \n";

    ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
    my $day = sprintf("%02d", $mday);
    my $month = sprintf("%02d", ++$mon);
    $year = 1900 + $year;

    my $filename = "$ip" . ".xml";
    my $outputfile = qq($datadir/$filename);
    my $archivedir = qq($datadir/$year/$month/$day);

    ###WJO
    #print "$outputfile \n";
    #print "$archivedir \n";
    #print "$datadir/$ip_dot \n";

    # NB: do this archive as user gstadmin as the mount may not allow root access
    # WJO: having trouble testing with su commands am going to modify the comands to perl 
    #      native commands and see about executing the script itself as gstadmin.
    ###TODO: das to remove this line: umask 0;
    if ( (-T "$outputfile") && ($ARGV[0] ne "-l")) {
        eval { mkpath($archivedir, $TRUE, 0777) };
        if ($@) {
            my $msg = "Couldn't create $archivedir: $@";
            die $msg;
        }
        if( copy( $outputfile, $archivedir ) ) {
            #print "Copy $outputfile, $archivedir\n";
        } else {
            die( "unable to copy $outputfile to $archivedir: $!\n" );
        }
    ###} elsif (! -T "$outputfile")  {
        ###print "Output File: $outputfile does not exist as text file\n";
    ###} else {
        ###print "Output File: $outputfile created.\n";
    }


    ## Now save today's data and copy it from its tmp location into place
    ## NB: do this creation as user gstadmin as the mount may not allow root access
    my $tmpdata = qq(/tmp/infradata-gst);
    my $datadir_TMP = qq($tmpdata/$datadir);
    my $target_u = "gstadmin";

    # If running with -l, save data locally
    if ($ARGV[0] eq "-l") {
        $tmpdata = qq($ARGV[1]/tmp.$$);
        $datadir_TMP = $tmpdata;
    }
    my $outputfile_TMP = qq($datadir_TMP/$filename);
    eval { mkpath($datadir_TMP, $TRUE, 0777) };
    if ($@) {
        my $msg = "Couldn't create $target_dir: $@";
        die $msg;
    }

    open DATAFILE, ">$outputfile_TMP" || die "cannot open output file: $outputfile_TMP: $!\n";
    print DATAFILE "$data\n";
    close DATAFILE;

    if ($ENV{USER} eq "root") {
        my $target_u = "gstadmin";

        ($login,$pass,$uid,$gid) = getpwnam($target_u);

        # What if gstadmin does not exist...?  Leave it all as root, I guess...
        if ($target_u ne $login) {
            "$target_u not in passwd file";
            return;
        }

        # Let's ensure this is owned by 'gstadmin' only
        ###system (qq(/bin/chown $target_u $outputfile_TMP));
        #symlinks should be owned by gstadmin user and the group staff/wheel (guid 10)
        chown $uid, $gid, $outputfile_TMP or die "unable to change owner of $outputfile_TMP: $!\n";

    } else {
        $target_u = $ENV{USER};
        ($login,$pass,$uid,$gid) = getpwnam($target_u);
    }


###print "Copy $outputfile_TMP, $outputfile\n";
    if( copy( $outputfile_TMP, $outputfile ) ) {
        #print "Copy $outputfile_TMP, $outputfile - success\n";
    } else {
        warn( "unable to copy $outputfile_TMP to $outputfile: $! - revert to command line\n" );
        ###&run_command( qq(/bin/su - gstadmin -c "/bin/cp -p $outputfile_TMP $outputfile") );
    }

    # Let's ensure this is owned by 'gstadmin' only
    ###das chown $uid, $gid, $outputfile or die "unable to change owner of $outputfile: $! to $uid\n";;

    # Let's ensure this can be read by anyone
    chmod 0644, $outputfile or die "unable to change permission of $outputfile: $!\n";;

    if (! -T "$outputfile") {
        die "Why did this not get created: $outputfile -- see $outputfile_TMP";
    }
 
    my $ip_dot_file = "$datadir/$ip_dot";
    if( -e $ip_dot_file ) {
        if( not unlink $ip_dot_file ) {
            warn "unable to delete $ip_dot_file: $! - attempt command line\n";
            &run_command( qq(/bin/su - $target_u -c "/bin/rm -f $ip_dot_file") );
        }
    }

    if( not symlink( $outputfile, $ip_dot_file ) ) {
        warn "unable to create symbolic link from $outputfile to $ip_dot_file: $! - revert to command line\n";
        &run_command( qq(/bin/su - $target_u -c "/bin/ln -s $outputfile $ip_dot_file") );
    }

    #PERL chown command does not support ownership of symlinks (http://www.perlmonks.org/?node_id=168970)
    system( qq(chown -h $uid:$gid $ip_dot_file) );
###system( qq(/bin/ls -l "$outputfile" "$ip_dot_file") );

    ## cleanup /tmp files -- 
    ## NB: be careful!!!!!  Removing files as root user!!!
    ## NB: essentially using $tmpdata definition, but hard-coded on purpose
    if( -e $outputfile_TMP ) {
        unlink $outputfile_TMP or warn "unable to delete $outputfile_TMP: $!\n";
    }

}

sub run_command {
    my $cmd = shift;
    my $ret_val = `$cmd`;
    print "Running: $cmd \n\t $ret_val\n";
}
#===============================================================================

if ($ARGV[0] eq "-l") {
    if (! -d $ARGV[1]) {
        print "Directory $ARGV[1] does not exist.  $0 @ARGV run aborted.\n";
        exit 1;
    }
}

&save_data(&get_data);

if ($ARGV[0] eq "-l") {
    rmdir $datadir_TMP;
}

1;
__END__
