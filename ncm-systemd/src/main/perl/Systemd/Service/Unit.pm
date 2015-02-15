# ${license-info}
# ${developer-info}
# ${author-info}
# ${build-info}

package NCM::Component::Systemd::Service::Unit;

use 5.10.1;
use strict;
use warnings;

use LC::Exception qw (SUCCESS);

use parent qw(CAF::Object Exporter);
use EDG::WP4::CCM::Element qw(unescape);
use NCM::Component::Systemd::Systemctl qw(
    systemctl_show 
    systemctl_list_units systemctl_list_unit_files
    systemctl_list_deps
    );

use Readonly;

Readonly our $TARGET_DEFAULT   => "default";
Readonly our $TARGET_RESCUE    => "rescue";
Readonly our $TARGET_MULTIUSER => "multi-user";
Readonly our $TARGET_GRAPHICAL => "graphical";
Readonly our $TARGET_POWEROFF  => "poweroff";
Readonly our $TARGET_REBOOT    => "reboot";

# default level (if default.target is not responding)
Readonly our $DEFAULT_TARGET => $TARGET_MULTIUSER;    

Readonly::Array my @TARGETS => qw($TARGET_DEFAULT 
    $TARGET_RESCUE $TARGET_MULTIUSER $TARGET_GRAPHICAL
    $TARGET_POWEROFF $TARGET_REBOOT);

Readonly our $TYPE_SYSV    => 'sysv';
Readonly our $TYPE_SERVICE => 'service';
Readonly our $TYPE_TARGET  => 'target';

Readonly::Array my @TYPES => qw($TYPE_SYSV $TYPE_SERVICE $TYPE_TARGET);

# Allowed states: enabled, disabled, masked
# Disabled does not imply OFF (can be started by other 
#   enabled service which has the disabled service as dependency)
# Use 'masked' if you really don't want something to be started/running.
Readonly our $STATE_ENABLED => "enabled";
Readonly our $STATE_DISABLED => "disabled"; 
Readonly our $STATE_MASKED => "masked";

Readonly::Array my @STATES => qw($STATE_ENABLED $STATE_DISABLED $STATE_MASKED);

# TODO should match schema default
Readonly our $DEFAULT_STARTSTOP => 1; # startstop true by default
Readonly our $DEFAULT_STATE => $STATE_ENABLED; # state on by default

our @EXPORT_OK = qw($DEFAULT_TARGET $DEFAULT_STARTSTOP $DEFAULT_STATE);
push @EXPORT_OK, @TARGETS, @TYPES, @STATES;

our %EXPORT_TAGS = (
    targets => \@TARGETS,
    types   => \@TYPES,
    states  => \@STATES,
);

# Cache of the unitfiles for service and target
my $unit_cache = {};

# Mapping of alias name to real name
my $unit_alias = {};

# Cache the dependencies and/or reverse dependencies
my $dependency_cache = {};

=pod

=head1 NAME

NCM::Component::Systemd::Service::Unit is a class handling services with units

=head2 Public methods

=over

=item new

Returns a new object, accepts the following options

=over

=item log

A logger instance (compatible with C<CAF::Object>).

=back

=cut

sub _initialize
{
    my ($self, %opts) = @_;

    $self->{log} = $opts{log} if $opts{log};

    return SUCCESS;
}

=pod

=item service_text

Convert service C<detail> hash to human readable string.

Generates errors for missing attributes.

=cut

sub service_text
{
    my ($self, $detail) = @_;

    my $text;
    if(exists($detail->{name})) {
        $text = "service $detail->{name} (";
    } else {
        $self->error("Service detail is missing name");
        return;
    }
       
    my @attributes = qw(state startstop type targets);
    my @attrtxt;
    foreach my $attr (@attributes) {
        my $val = $detail->{$attr};
        if (defined($val)) {
            my $tmptxt = "$attr "; 
            if(ref($val) eq 'ARRAY') {
                $tmptxt .= join(',', @$val);
            } else {
                $tmptxt .= $val;
            }
            push(@attrtxt, $tmptxt);
        } else {
            $self->error("Service $detail->{name} details is missing attribute $attr");
        }
    }

    $text .= join(' ', @attrtxt) . ")";

    return $text;
}

=pod

=item current_services

Return hash reference with current configured services 
determined via C<make_cache_alias>.

All additional arguments are a list of C<units> 
that is passed to C<make_cache_alias>.

This method also rebuilds the cache and alias map.

=cut

sub current_services
{
    my ($self, @units) = @_;

    # TODO: always update cache?
    $self->init_cache($TYPE_SERVICE);

    $self->make_cache_alias($TYPE_SERVICE, @units);

    my %current;
    
    while (my ($name,$data) = each %{$unit_cache->{$TYPE_SERVICE}}) {
        my $detail = {name => $name, type => $TYPE_SERVICE};

        # TODO: can we refine this somehow? Or does it make no sense.
        $detail->{startstop} = $DEFAULT_STARTSTOP;

        my $show = $data->{show};
        if(! defined($show)) {
            if ($data->{baseinstance}) {
                $self->verbose("Base instance $name is not an actual runnable service. Skipping.");
            } elsif(@units) {
                # Lots of units that have no show data, because they aren't queried all.
                $self->verbose("Found name $name without any show data; ",
                               "only selected units were queried. Skipping.");
            } else {
                $self->error("Found name $name without any show data. Skipping.");
            }
            next;
        }

        my $load = $show->{LoadState};
        my $active = $show->{ActiveState};
        my $substate = $show->{SubState};

        $self->debug(1, "Found service unit $detail->{name} with ",
                       "LoadState $load ActiveState $active");

        my $wanted = $show->{WantedBy};
        $detail->{targets} = [];
        if (defined($wanted)) {
            # TODO resolve further implied targets (a.k.a reverse dependencies)? 
            #   e.g. if multi-user.target is wanted-by graphical.target, do we add
            #   graphical.target here too? 
            foreach my $target (@$wanted) {
                # strip .target (but there can be non .target reverse dependencies)
                $target =~ s/\.target$//;
                push(@{$detail->{targets}}, $target);
            }
        } else {
            $self->verbose("No WantedBy defined for service unit $detail->{name}");
        }
        
        # If a service is WantedBy / has a target, it is enabled.
        # This is the only relevant difference between a sysv service
        #   using the old chkconfig on and off
        if(@{$detail->{targets}}) {
            $detail->{state} = $STATE_ENABLED;
        } else {
            $detail->{state} = $STATE_DISABLED;
        }

        $self->debug(1, "current_services added unit file service $detail->{name}");
        $self->debug(2, "current_services added unit file ", $self->service_text($detail));
        $current{$name} = $detail;
    }

    return \%current;
}

=pod

=item current_target

Return the current target.

TODO: implement this. systemctl list-units --type target 
lists all current targets (yes, with an s).

=cut

=pod

=item default_target

Return the default target.

=cut

sub default_target
{
    my ($self) = @_;

    my $default = "$TARGET_DEFAULT.target";

    # TODO: use cache?
    my $show = systemctl_show($self, $default);

    my $id = $show->{Id};

    if ($id) {
        $self->verbose("Default target based on $default corresponds with Id $id");
    } else {
        $self->error("Can't determine default target based on $default. Using $DEFAULT_TARGET as fall-back.");
        $id = $DEFAULT_TARGET;
    }

    $id =~ s/\.target$//;

    return $id;
}

=pod

=item configured_services

C<configured_services> parses the C<tree> hash reference and builds up the
services to be configured. It returns a hash reference with key the service name and 
values the details of the service.

(C<tree> is typically C<$config->getElement('/software/components/systemd/service')->getTree>.)

=cut

sub configured_services
{
    my ($self, $tree) = @_;

    my %services;
    
    while (my ($service, $detail) = each %$tree) {
        # only set the name (not mandatory in new schema, to be added here)
        $detail->{name} = unescape($service) if (! exists($detail->{name}));

        # all new services are assumed type service
        $detail->{type} = $TYPE_SERVICE if (! exists($detail->{type}));
        
        $self->verbose("Add service name $detail->{name} (service $service)");
        $self->debug(1, "Add ", $self->service_text($detail));
        
        $services{$detail->{name}} = $detail;
    }

    # TODO figure out a way to specify what off-targets and what on-targets mean.
    # If on is defined, all other targets are off
    # If off is defined, all others are on or also off? (2nd case: off means off everywhere) 
    
    return \%services;
}


=pod

=back

=head2 Private methods

=over

=item init_cache

(Re)Initialise all unit caches. If a C<type> is specified, 
only those cache will be (re)initialised.

Returns the caches (for unittestung mainly).

Affected caches are

=over

=item unit_cache

=item unit_alias

=item dependency_cache

=back

=cut

sub init_cache
{
    my ($self, $type) = @_; 

    if(defined $type) {
        $self->verbose("Initialisation of all caches for type $type.");

        # reset unit_cache and alias for current type
        $unit_cache->{$type} = {};
        $unit_alias->{$type} = {};
        
        $self->verbose("Type $type initiliasation of dependency_cache not supported.");
    } else {
        $self->verbose("Initialisation of all caches.");

        $unit_cache = {
            service => {}, 
            target => {}
        };

        $unit_alias = {
            service => {}, 
            target => {}
        };
        
        $dependency_cache = {
            deps => {},
            rev => {},
        };
    }

    # For unittesting
    return $unit_cache, $unit_alias, $dependency_cache;
}

=pod

=item make_cache_alias

(Re)generate the C<unit_cache> and C<unit_alias> map 
based on current units and unitfiles for C<type>. 

Details for each unit from C<units> are also added. 
If C<units> is empty/undef, all found units and unitfiles 
are. Units without a type specifier are assumed of type
C<type>. 

Each found unit is also added as it's own alias.

Supported types are C<service> and C<target>.

Returns the generated cache and alias map for unittesting purposes.

=cut

sub make_cache_alias
{
    my ($self, $type, @units) = @_;

    my $treg = '^(' . join('|', $TYPE_SERVICE, $TYPE_TARGET) . ')$';
    if (!($type && $type =~ m/$treg/)) {
        $self->error("Undefined or wrong type $type for systemctl list-unit-files / list-units");
        return;
    }

    my $units = systemctl_list_units($self, $type);
    my $unit_files = systemctl_list_unit_files($self, $type);
    
    # Join them, keep data
    while (my ($name, $data) = each %$units) {
        $unit_cache->{$type}->{$name}->{unit} = $data;
    }
    while (my ($name, $data) = each %$unit_files) {
        $unit_cache->{$type}->{$name}->{unit_file} = $data;
    }

    # Unknown names, to be checked if aliases
    my @unknown;
    if (@units) {
        # Strip the type
        my $reg = '\.'.$type.'$';
        @units = map { $_ =~ s/$reg//; $_ } @units;
    } else {
        @units = sort keys %{$unit_cache->{$type}};
    }
    foreach my $name (@units) {
        my $data = $unit_cache->{$type}->{$name};

        if (! defined $data) {
            # no entry in cache from units or unitfiles
            $self->error("Trying to add details of unit $name type $type ",
                         "but no entry in cache after adding all units and unitfiles. ",
                         "Ignoring this unit.");
            next;
        }

        # check for instances
        my $instance;
        if ($name =~ m/^(.*?)\@(.*)?$/) {
            $instance = $2;

            if ($instance eq "") {
                # A unit-file for instance-units (this shouldn't be an instance / unit).
                $data->{baseinstance} = 1;

                if (exists $data->{unit}) {
                    $self->error("$name is an instance base unit-file; should not be listed as a unit.");
                } else {
                    $self->verbose("$name is an instance base unit-file; nothing to show");
                }

                next;
            } else {
                $self->debug(1, "Name $name is an instance ($instance)");
                $data->{instance} = $instance;
            }
        }

        my $fullname = "$name.$type";
        my $show = systemctl_show($self, $fullname);

        if(!defined($show)) {
            $self->error("Found $type unit $name but systemctl_show returned undef. ",
                        "Skipping this unit");
            next;
        };

        my $pattern = '^(.*)\.'.$type.'$';
        my $id;
        if ($show->{Id} =~ m/$pattern/) {
            $id = $1;
            if ($id eq $name) {
                $data->{show} = $show;            
                $self->debug(1, "Added type $type name $name to cache.");
            } else {
                $self->verbose("Found id $id that doesn't match name $name. ",
                               "Adding as unknown and skipping further handling.");
                # in particular, no aliases are processed/followed 
                # not to risk anything being overwritten

                # add the real name to the list of units to check
                # TODO potential issue for infinite loop because the type is removed?
                if(! grep {$id eq $_} @units) {
                    $self->verbose("Adding the id $id from unkown name $name to list of units");
                    push(@units, $id);
                };

                push(@unknown, [$name, $id, $show]);
                next;
            }
        } else {
            $self->error("Found Id $show->{Id} for name $name type $type that ",
                         "doesn't match expected pattern '$pattern'. ",
                         "Skipping this unit.");
            next;
        }

        foreach my $alias (@{$show->{Names}}) {
            if ($alias =~ m/$pattern/) {
                $unit_alias->{$type}->{$1} = $id;
                $self->debug(1, "Added type $type alias $1 of id $id to map.");
            } else {
                $self->error("Found alias $alias that doesn't match expected pattern '$pattern'. Skipping.");
            }
        }
    }

    # Check the unknowns (this completes the aliases)
    foreach my $unknown (@unknown) {
        my ($name, $id, $show) = @$unknown;

        my $realname = $unit_alias->{$type}->{$name};
        if(defined $realname) {
            $self->debug(1 ,"Unknown $name / $id is an alias for $type $realname");
        } else {
            # Most likely the realname does not list this name in its Names list
            # Maybe this is an alias of an alias? (We don't process the aliases, 
            # so their aliases are not added)
            # TODO: add it as alias or always error?
            my $realid = $unit_alias->{$type}->{$id};
            if (defined $realid) {
                my $cache = $unit_cache->{$type}->{$realid};
                if ($cache->{baseinstance}) {
                    $self->verbose("Unknown $name / $id is $type base instance and has missing alias entry.",
                                   " Adding it.");
                } else {
                    my $realshow = $cache->{show};
                    $self->verbose("Unknown $name / $id has missing $type alias entry. Adding it.",
                                   " Names ", join(', ', @{$show->{Names}}),
                                   " real Names ", join(', ', @{$realshow->{Names}}),
                                   ".");
                }
                $unit_alias->{$type}->{$name} = $realid;
            } else {
                $self->error("Found unknown name $name for type $type with ",
                             "id $id (full $show->{Id}) names ", 
                             join(', ', @{$show->{Names}}), 
                             ".");
            }                    
        }
    }

    # Check if each alias' real name has an existing entry in cache
    while (my ($alias, $name) = each %{$unit_alias->{$type}} ) {
        if($alias ne $name && exists($unit_cache->{$type}->{$alias})) {
            # removing any aliases that got in the unit_cache
            $self->debug(1, "Removing alias $alias of $name from $type cache");
            delete $unit_cache->{$type}->{$alias};
        }

        if (! defined $unit_cache->{$type}->{$name}) {
            $self->error("Real unit $name.$type of alias $alias has no entry in $type cache");
            next;
        }

    }

    # For unittesting purposes    
    return $unit_cache->{$type}, $unit_alias->{$type};
}

=pod

=item wanted_by

Return if C<service> is wanted by C<target>. 

Any unit can be passed as C<service> or C<target>; but in 
absence of a type specifier resp. C<.service> and C<.target> will
be used.

It uses the dependecy_cache for reverse dependencies

=cut

sub wanted_by
{
    my ($self, $service, $target) = @_;

    if($service !~ m/\.\w+$/) {
        $service .= ".$TYPE_SERVICE";
    }

    if($target !~ m/\.\w+$/) {
        $target .= ".$TYPE_TARGET";
    }

    # Try lookup from reverse cache. 
    # If not found in cache, look it up via systemctl_list_deps 
    # with reverse enabled.
    if(! defined $dependency_cache->{rev}->{$service}) {
        $self->verbose("No cache for dependency for service $service and target $target.");
        my $deps = systemctl_list_deps($self, $service, 1);
        $dependency_cache->{rev}->{$service} = $deps;
    } else {
        $self->verbose("Dependency for service $service and target $target in cache.");
    }

    return $dependency_cache->{rev}->{$service}->{$target};

}

=pod

=item is_active

C<is_active> returns true or false and reflects if a unit is "running" or not.

The following options are supported

=over

=item force

This is based on cached values, set C<force> to true to force a cache update 
(default false).

=item sleeptime
=item max

Units that are 'reloading', 'activating' and 'deactivating' are refreshed with 
C<sleep> (default 1 sec) and C<max> number of tries (default 3). Until 

=item type

Specify the C<type> of the unit (otherwise it is derived from the unit name or 
default 'service' is assumed) 

=back

=cut

sub is_active
{
    my ($self, $unit, %opts) = @_;
    
    my $force = exists($opts{force}) ? $opts{force} : 0;
    my $sleep = exists($opts{sleep}) ? $opts{sleep} : 1;
    my $max = exists($opts{max}) ? $opts{max} : 3;

    $self->verbose("Running is_active with force $force sleep $sleep max $max");

    my $type;
    my $treg = '\.(' . join('|', $TYPE_SERVICE, $TYPE_TARGET) . ')$';
    if ($opts{type}) {
        $type = $opts{type};
        $self->verbose("Set type $type for unit $unit.");        
    } elsif ($unit =~ m/$treg/) {
        $type = $1;
        $self->verbose("Found type $type based on unit $unit.");
    } else {
        $type = $TYPE_SERVICE;
        $self->verbose("Could not determine type based on unit $unit ",
                       "and pattern $treg. Using default type $type.");
    }

    if ($force) {
        $self->verbose("Force updating the cache for the unit $unit.");
        $self->make_cache_alias($type, $unit);
    }

    # The cache unit name as used in make_cache_alias
    my $cunit = $unit;
    my $reg = '\.'.$type.'$';
    $cunit =~ s/$reg//;

    my $active = $unit_cache->{$type}->{$cunit}->{show}->{ActiveState};
    if (! defined($active)) {
        $self->error("No ActiveState for unit $unit (cunit $cunit) found.");
        return;
    }
 
    # Possible ActiveState values from systemd dbus interface
    # http://www.freedesktop.org/wiki/Software/systemd/dbus/

    my @inter = qw(reloading activating deactivating);

    my $tries = 0;
    while ((grep {$_ eq $active} @inter)) {
        my $msg = "the cache for the unit $unit due to intermittent state $active";
        if ($tries < $max) {
            sleep($sleep);
            $self->make_cache_alias($type, $unit);
            $active = $unit_cache->{$type}->{$cunit}->{show}->{ActiveState};
            if (! defined($active)) {
                $self->error("No ActiveState for unit $unit (cunit $cunit) found ($tries of max $max).");
                return;
            }
            $self->verbose("Updating $msg. New state $active.");
            $tries++;
        } else {
            # Map the intermediate states to a final state.
            # We are going to assume all will be fine.
            if($active eq 'deactivating') {
                $active = 'inactive';
            } else {
                $active = 'active';
            }
            $self->verbose("Max tries for updating $msg. Forced mapping to $active.");
        }
    }

    # Must be one of the final states now.
    my @final = qw(active inactive failed);
    if (grep {$_ eq $active} @final) {
        if ($active eq 'active') {
            $self->verbose("Active $active, is_active true");
            return 1;
        } else {
            $self->verbose("Active $active, is_active false");
            return 0;
        }
    } else {
        $self->error("Unsupported ActiveState $active. (Component version too old?)");
        return;
    }
}

=pod

=back

=cut 

1;
