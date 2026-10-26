package PVE::Storage::LunCmd::OviOSiSCSI;

# iscsi storage running on OviOS Linux
# ovios.org
# On one of the proxmox nodes:
# 1) Login as root
# 2) ssh-copy-id <ip_of_iscsi_storage>

use strict;
use warnings;

use PVE::Tools qw(run_command);

sub get_base;

my $MAX_LUNS = 16384;
my @ssh_opts = ('-q', '-o', 'BatchMode=yes');
my @ssh_cmd = ('/usr/bin/ssh', @ssh_opts);
my $id_rsa_path = '/etc/pve/priv/zfs';
my $tgtadm = '/usr/sbin/tgtadm';
my $zfs = '/usr/sbin/zfs';

# Live state of the target we are talking to: { tid => N, luns => [ {lun, Path, include} ] }
# It is re-read from the OviOS box on every run_lun_command, because the pve
# workers are long lived and other workers/nodes change the target behind our back.
my $SETTINGS = undef;

# Runs "$method @params" on the OviOS box over ssh. Returns { result => 0|1, msg => ... }.
my $execute_command = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $msg = '';
    my $err = '';

    $timeout = 10 if !$timeout;

    my $output = sub {
        my $line = shift;
        $msg .= "$line\n";
    };

    my $errfunc = sub {
        my $line = shift;
        $err .= "$line\n";
    };

    my $target = 'root@' . $scfg->{portal};
    my $cmd = [@ssh_cmd, '-i', "$id_rsa_path/$scfg->{portal}_id_rsa", $target, '--', $method, @params];

    eval {
        run_command($cmd, outfunc => $output, errfunc => $errfunc, timeout => $timeout);
    };
    if (my $exc = $@) {
        return { result => 0, msg => ($err ne '' ? $err : $exc) };
    }

    return { result => 1, msg => $msg };
};

# Reads the mapped luns of $scfg->{target} from the live tgt state.
my $parse_config = sub {
    my ($scfg) = @_;

    my $base = get_base();
    my $listcmd = "$tgtadm --lld iscsi --mode target --op show"
        . ' | /bin/grep -E "Target | LUN: | Backing store path:"';

    my $res = $execute_command->($scfg, undef, $listcmd);
    die "unable to read target configuration from $scfg->{portal}: $res->{msg}\n"
        unless $res->{result};

    my $settings = { tid => undef, luns => [] };
    my $in_target = 0;
    my $lun_id = undef;

    foreach my $line (split /\n/, $res->{msg}) {
        $line =~ s/^\s+|\s+$//g;

        if ($line =~ /^Target\s+(\d+):\s*(\S+)/) {
            $in_target = ($2 eq $scfg->{target});
            $lun_id = undef;
            if ($in_target) {
                die "Parse error: target $scfg->{target} listed twice\n" if defined $settings->{tid};
                $settings->{tid} = $1;
            }
        } elsif ($in_target && $line =~ /^LUN:\s*(\d+)/) {
            $lun_id = $1;
        } elsif ($in_target && defined $lun_id && $line =~ /^Backing store path:\s*(.+)$/) {
            my ($lun, $path) = ($lun_id, $1);
            $lun_id = undef;
            next if $lun == 0; # LUN 0 is the controller
            push @{$settings->{luns}}, {
                lun => $lun,
                Path => $path,
                include => ($path =~ m{^\Q$base/$scfg->{pool}\E/[\w.\-]+$}) ? 1 : 0,
            };
        }
    }

    die "target $scfg->{target} not found on $scfg->{portal}\n" if !defined $settings->{tid};

    return $settings;
};

my $find_lun = sub {
    my ($path) = @_;

    foreach my $lun (@{$SETTINGS->{luns}}) {
        next unless $lun->{include};
        return $lun if $lun->{Path} eq $path;
    }
    return undef;
};

my $get_free_lun_id = sub {
    my %used = map { $_->{lun} => 1 } @{$SETTINGS->{luns}};

    for (my $i = 1; $i < $MAX_LUNS; $i++) {
        return $i if !$used{$i};
    }
    die "Maximum number of LUNs per target is $MAX_LUNS\n";
};

# Persist the running tgt config. Dump to a temp file first so a failing dump
# can never truncate the existing targets.conf.
my $update_config = sub {
    my ($scfg) = @_;

    my $conf = '/etc/tgt/targets.conf';
    my $res = $execute_command->($scfg, undef,
        "/usr/sbin/tgt-ovadmin --dump > $conf.new && [ -s $conf.new ] && mv -f $conf.new $conf");
    warn "unable to update $conf on $scfg->{portal}: $res->{msg}\n" if !$res->{result};
};

# OviOS bookkeeping flags on the zvol.
my $set_flags = sub {
    my ($scfg, $timeout, $path, $mapped, $lun_id) = @_;

    my $base = get_base();
    (my $ds = $path) =~ s{^\Q$base\E/}{};

    my @props = $mapped
        ? ('lun:mapped=yes', 'lun:type=proxmox', "lun:id=$lun_id", "lun:tg-name=$scfg->{target}")
        : ('lun:mapped=no', 'lun:type=none', 'lun:id=none', 'lun:tg-name=none');

    my $res = $execute_command->($scfg, $timeout, $zfs, 'set', @props, $ds);
    warn "unable to set OviOS lun flags on $ds: $res->{msg}\n" if !$res->{result};
};

my $add_logical_unit = sub {
    my ($scfg, $timeout, $lun_id, $path) = @_;

    my $res = $execute_command->($scfg, $timeout, $tgtadm, '--lld', 'iscsi', '--op', 'new',
        '--mode', 'logicalunit', '--tid', $SETTINGS->{tid}, '--lun', $lun_id, '-b', $path);
    die $res->{msg} unless $res->{result};
};

my $delete_logical_unit = sub {
    my ($scfg, $timeout, $lun_id) = @_;

    my $res = $execute_command->($scfg, $timeout, $tgtadm, '--lld', 'iscsi', '--op', 'delete',
        '--mode', 'logicalunit', '--tid', $SETTINGS->{tid}, '--lun', $lun_id);
    die $res->{msg} unless $res->{result};
};

my $list_view = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $lun = $find_lun->($params[0]);
    return $lun ? $lun->{lun} : undef;
};

my $list_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $lun = $find_lun->($params[0]);
    return $lun ? $lun->{Path} : undef;
};

my $create_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $path = $params[0];
    die "$path: LUN exists\n" if $find_lun->($path);

    my $lun_id = $get_free_lun_id->();
    $add_logical_unit->($scfg, $timeout, $lun_id, $path);

    $update_config->($scfg);
    $set_flags->($scfg, $timeout, $path, 1, $lun_id);

    return $path;
};

my $delete_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $lun = $find_lun->($params[0]);
    return '' if !$lun; # nothing mapped, nothing to do

    $delete_logical_unit->($scfg, $timeout, $lun->{lun});
    $update_config->($scfg);

    return '';
};

my $import_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    return $create_lun->($scfg, $timeout, $method, @params);
};

# tgt has no online resize: the LU is removed and re-added so that it picks up
# the new zvol size. params: (new size, lu name == backing path)
my $modify_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $path = $params[1];
    my $lun = $find_lun->($path);
    die "$path: LUN not found\n" if !$lun;

    $delete_logical_unit->($scfg, $timeout, $lun->{lun});
    $set_flags->($scfg, $timeout, $path, 0);

    eval { $add_logical_unit->($scfg, $timeout, $lun->{lun}, $path); };
    if (my $err = $@) {
        $update_config->($scfg);
        die "failed to re-add LUN $lun->{lun} for $path after resize, the disk is unmapped: $err";
    }

    $set_flags->($scfg, $timeout, $path, 1, $lun->{lun});
    $update_config->($scfg);

    return '';
};

my $add_view = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    return '';
};

my $get_lun_cmd_map = sub {
    my ($method) = @_;

    my $cmdmap = {
        create_lu   =>  { cmd => $create_lun },
        delete_lu   =>  { cmd => $delete_lun },
        import_lu   =>  { cmd => $import_lun },
        modify_lu   =>  { cmd => $modify_lun },
        add_view    =>  { cmd => $add_view },
        list_view   =>  { cmd => $list_view },
        list_lu     =>  { cmd => $list_lun },
    };

    die "unknown command '$method'" unless exists $cmdmap->{$method};

    return $cmdmap->{$method};
};

sub run_lun_command {
    my ($scfg, $timeout, $method, @params) = @_;

    my $cmdmap = $get_lun_cmd_map->($method);
    $SETTINGS = $parse_config->($scfg);
    my $msg = $cmdmap->{cmd}->($scfg, $timeout, $method, @params);

    return $msg;
}

sub get_base {
    return '/dev/zvol';
}

1;
