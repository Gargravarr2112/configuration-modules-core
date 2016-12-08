#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 15;
use Test::NoWarnings;
use Test::Quattor qw(client server bug);
use NCM::Component::named;
use Readonly;
use CAF::Object;
Test::NoWarnings::clear_warnings();


# $RESOLV_CONF_CONTENTS_1 is the expected file.
# Comments are preceded by 2 tabs.
Readonly my $RESOLV_CONF_CONTENTS_1 => '# Generated by NetworkManager
domain lal.in2p3.fr
search lal.in2p3.fr
options timeout:2 debug
nameserver 134.158.88.149		# added by Quattor
nameserver 134.158.88.147		# added by Quattor
';

Readonly my $RESOLV_CONF_CONTENTS_2 => '# Generated by NetworkManager
domain lal.in2p3.fr
search lal.in2p3.fr
options timeout:2 something else
nameserver 134.158.88.123               # added by Quattor
nameserver 134.158.88.456               # added by Quattor
';

Readonly my $RESOLV_CONF_CONTENTS_3 => '# Generated by NetworkManager
domain lal.in2p3.fr
search lal.in2p3.fr
options woo hoo
';

Readonly my $RESOLV_CONF_CONTENTS_4 => '# Generated by somebody
search nowhere.com
nameserver 1.2.3.4';

# sysconfig file for named daemon
Readonly my $NAMED_SYSCONFIG_CONTENTS_1 => ' # BIND named process options
# ~~~~~~~~~~~~~~~~~~~~~~~~~~
# Currently, you can use the following options:
#
# ROOTDIR="/var/named/chroot"  --  will run named in a chroot environment.
#                            you must set up the chroot environment 
#                            (install the bind-chroot package) before
#                            doing this.
#	NOTE:
#         Those directories are automatically mounted to chroot if they are
#         empty in the ROOTDIR directory. It will simplify maintenance of your
#         chroot environment.
#          - /var/named
#          - /etc/pki/dnssec-keys
#          - /etc/named
#          - /usr/lib64/bind or /usr/lib/bind (architecture dependent)
#
#	  Those files are mounted as well if target file does not exist in
#	  chroot.
#          - /etc/named.conf
#          - /etc/rndc.conf
#          - /etc/rndc.key
#          - /etc/named.rfc1912.zones
#          - /etc/named.dnssec.keys
#	   - /etc/named.iscdlv.key
#
#	Do not forget to add "$AddUnixListenSocket /var/named/chroot/dev/log"
#	line to your /etc/rsyslog.conf file. Otherwise your logging becomes
#	broken when rsyslogd daemon is restarted (due update, for example).
#
# OPTIONS="whatever"     --  These additional options will be passed to named
#                            at startup. Do not add -t here, use ROOTDIR instead.
#
# KEYTAB_FILE="/dir/file"    --  Specify named service keytab file (for GSS-TSIG)
#
# DISABLE_ZONE_CHECKING  -- By default, initscript calls named-checkzone
#			    utility for every zone to ensure all zones are
#			    valid before named starts. If you set this option
#			    to yes then initscript does not perform those
#			    checks.
#ROOTDIR="/var/named/chroot"
';

Readonly my $NAMED_SYSCONFIG_CONTENTS_2 => ' # BIND named process options
# ~~~~~~~~~~~~~~~~~~~~~~~~~~
# Currently, you can use the following options:
#
# ROOTDIR="/var/named/chroot"  --  will run named in a chroot environment.
#                            you must set up the chroot environment
#                            (install the bind-chroot package) before
#                            doing this.
#       NOTE:
#         Those directories are automatically mounted to chroot if they are
#         empty in the ROOTDIR directory. It will simplify maintenance of your
#         chroot environment.
#          - /var/named
#          - /etc/pki/dnssec-keys
#          - /etc/named
#          - /usr/lib64/bind or /usr/lib/bind (architecture dependent)
#
#         Those files are mounted as well if target file does not exist in
#         chroot.
#          - /etc/named.conf
#          - /etc/rndc.conf
#          - /etc/rndc.key
#          - /etc/named.rfc1912.zones
#          - /etc/named.dnssec.keys
#          - /etc/named.iscdlv.key
#
#       Do not forget to add "$AddUnixListenSocket /var/named/chroot/dev/log"
#       line to your /etc/rsyslog.conf file. Otherwise your logging becomes
#       broken when rsyslogd daemon is restarted (due update, for example).
#
# OPTIONS="whatever"     --  These additional options will be passed to named
#                            at startup. Do not add -t here, use ROOTDIR instead.
#
# KEYTAB_FILE="/dir/file"    --  Specify named service keytab file (for GSS-TSIG)
#
# DISABLE_ZONE_CHECKING  -- By default, initscript calls named-checkzone
#                           utility for every zone to ensure all zones are
#                           valid before named starts. If you set this option
#                           to yes then initscript does not perform those
#                           checks.
ROOTDIR="/var/named/chroot"
#ROOTDIR="/var/named/chroot"
';

# Expected named config file contents
Readonly my $NAMED_CONFIG_CONTENTS => "// testdata
Creature. Grass image cattle their. Hath, third itself won't lights likeness were divided. Brought Hath dry.
";

$CAF::Object::NoAction = 1;

=pod

=head1 SYNOPSIS

This is a test suite for ncm-named (client configuration).

=cut

my $cmp = NCM::Component::named->new('named');
my $config = get_config_for_profile("bug");

# Test for a bug in which the search line is not terminated correctly.
set_file_contents($RESOLVER_CONF_FILE, $RESOLV_CONF_CONTENTS_4);
$cmp->Configure($config);
my $fh = get_file($RESOLVER_CONF_FILE);
like("$fh", qr{search somewhere.org here.fr\nnameserver 4.3.2.1},
     "Newlines added correctly when the search directive is modified");
$fh->close();


# Client configuration
$config = get_config_for_profile('client');

set_file_contents($RESOLVER_CONF_FILE, $RESOLV_CONF_CONTENTS_1);
$cmp->Configure($config);
$fh = get_file($RESOLVER_CONF_FILE);
ok(defined($fh), "$RESOLVER_CONF_FILE was opened (1)");
is("$fh",$RESOLV_CONF_CONTENTS_1,"$RESOLVER_CONF_FILE has expected contents (1)");
$fh->close();

set_file_contents($RESOLVER_CONF_FILE, $RESOLV_CONF_CONTENTS_2);
$cmp->Configure($config);
$fh = get_file($RESOLVER_CONF_FILE);
ok(defined($fh), "$RESOLVER_CONF_FILE was opened (2)");
is("$fh",$RESOLV_CONF_CONTENTS_1,"$RESOLVER_CONF_FILE has expected contents (2)");
$fh->close();

set_file_contents($RESOLVER_CONF_FILE, $RESOLV_CONF_CONTENTS_3);
$cmp->Configure($config);
$fh = get_file($RESOLVER_CONF_FILE);
ok(defined($fh), "$RESOLVER_CONF_FILE was opened (3)");
is("$fh",$RESOLV_CONF_CONTENTS_1,"$RESOLVER_CONF_FILE has expected contents (3)");
$fh->close();

# Server configuration

set_command_status("/sbin/chkconfig --list", "0");
set_command_status("/sbin/chkconfig --list named", "0");
my $named_root_dir = $cmp->getNamedRootDir();
my $named_conf_file = $named_root_dir.$NAMED_CONFIG_FILE;

# client/server with named.conf from other source
# i.e. no config data set in profile (like this pure-client)
$cmp->Configure($config);
$fh = get_file($named_conf_file);
ok(! defined($fh), "$named_conf_file not opened / modified with FileWriter for client");

# actual server with named.conf under ncm-named control
set_file_contents($NAMED_SYSCONFIG_FILE, $NAMED_SYSCONFIG_CONTENTS_1);
$config = get_config_for_profile("server");
$cmp->Configure($config);
$fh = get_file($named_conf_file);
ok(defined($fh), "$named_conf_file was opened (1)");
# overwrites the external data
is("$fh", $NAMED_CONFIG_CONTENTS, "$named_conf_file has expected contents (1)");
$fh->close();

set_file_contents($NAMED_SYSCONFIG_FILE, $NAMED_SYSCONFIG_CONTENTS_2);
set_command_status("/sbin/chkconfig --list", "0");
set_command_status("/sbin/chkconfig --list named", "0");
$named_root_dir = $cmp->getNamedRootDir();
like($named_root_dir,qr{^/[-\w\./]+$},"Named chrooted");
$named_conf_file = $named_root_dir.$NAMED_CONFIG_FILE;
$cmp->Configure($config);
$fh = get_file($named_conf_file);
ok(defined($fh), "$named_conf_file was opened (2)");
is("$fh",$NAMED_CONFIG_CONTENTS,"$named_conf_file has expected contents (2)");
$fh->close();


Test::NoWarnings::had_no_warnings();
