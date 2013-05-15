use Bio::KBase::KIDL::typedoc;
use strict;
use POSIX;
use Data::Dumper;
use Template;
use File::Slurp;
use File::Basename;
use File::Path 'make_path';
use Bio::KBase::KIDL::KBT;
use Getopt::Long;

=head1 NAME

compile_typespec

=head1 SYNOPSIS

compile_typespec [arguments] spec-file output-dir

=head1 DESCRIPTION

compile_typespec is the KBase type compiler. It reads a KBase Interface Description
Language (KIDL) file and generates the client and server interface code for it.

=head1 COMMAND-LINE OPTIONS

Usage: compile_typespec [arguments] spec-file output-dir

Arguments:

    --scripts dir	       Generate simple wrapper scripts
    --impl name		       Use name as the classname for the generated perl implementation module
    --service name	       Use name as the classname for the generated service module
    --psgi name		       Write a PSGI file as name
    --client name	       Use name as the classname for the generated client module
    --js name		       Use name as the basename for the generated Javascript client module
    --py name		       Use name as the basename for the generated Python client module
    --url URL		       Use URL as the default service URL in the generated clients
    --dump		       Dump the parsed type specification file to stdout

=head1 AUTHORS

Robert Olson, Argonne National Laboratory olson@mcs.anl.gov

=cut

my $scripts_dir;
my $impl_module_base;
my $service_module;
my $client_module;
my $psgi;
my $js_module;
my $py_module;
my $py_server_module;
my $py_impl_module;
my $include_path;
my $default_service_url;
my $dump_parsed;
my $test_script;
my $help;

my $rc = GetOptions("scripts=s" => \$scripts_dir,
                    "impl=s"    => \$impl_module_base,
                    "service=s" => \$service_module,
                    "psgi=s"    => \$psgi,
                    "client=s"  => \$client_module,
                    "test=s"    => \$test_script,
                    "js=s"      => \$js_module,
                    "py=s"      => \$py_module,
                    "pyserver=s"=> \$py_server_module,
                    "pyimpl=s"  => \$py_impl_module,
                    "path=s"    => \$include_path,
                    "url=s"     => \$default_service_url,
                    "dump"      => \$dump_parsed,
                    "help|h"	=> \$help,
                    );

if (!$rc || $help || @ARGV < 2)
{
    seek(DATA, 0, 0);
    while (<DATA>)
    {
	last if /^=head1 COMMAND-LINE /;
    }
    while (<DATA>)
    {
	last if /^=/;
	print $_;
    }
    exit($help ? 0 : 1);
}

($rc && @ARGV >= 2) or die "Usage: $0 [--psgi psgi-file] [--impl impl-module] [--service service-module] [--client client-module] [--scripts script-dir] [--py python-module ] [--pyserver python-server-module] [--pyimpl python-implementation-module][--js js-module] [--url default-service-url] [--test test-script] [--path include-path] typespec [typespec...] output-dir\n";

my $output_dir = pop;
my @spec_files = @ARGV;

if ($scripts_dir && ! -d $scripts_dir)
{
    die "Script output directory $scripts_dir does not exist\n";
}
my $parser = typedoc->new();

#
# Read and parse all the given documents. We collect all documents
# that comprise each service, and process the services as units.
#

my %services;
my $available_type_table; # this is global over all modules included, and keeps a table of all available types

my $errors_found;

for my $spec_file (@spec_files)
{
    my $txt = read_file($spec_file) or die "Cannot read $spec_file: $!";
    my($modules, $errors) = $parser->parse($txt, $spec_file);
    #print Dumper($modules);
    # WARNING!! we need to merge the hashes here to properly handle multiple spec files!!
    $available_type_table = $parser->YYData->{cached_type_tables};
    my $type_info = assemble_types($parser);  #type_info is now a hash with module names as keys, and lists as before
    if ($errors)
    {
        print STDERR "$errors errors were found in $spec_file\n";
        $errors_found += $errors;
    }
    for my $mod (@$modules)
    {
        my $mod_name = $mod->module_name;
        my $serv_name = $mod->service_name;
        print STDERR "$spec_file: module $mod_name service $serv_name\n";
        #push(@{$services{$serv_name}}, [$mod, $type_info, $parser->YYData->{type_table}]);
        push(@{$services{$serv_name}}, [$mod, $type_info->{$mod_name}, $available_type_table->{$mod_name}]);
    }
}
if ($errors_found)
{
    exit 1;
}

print "-------------all parsed\n";
print Dumper(\%services)."\n";

#
# Determine if we have any authentication-optional or -required methods. If any of
# these exist, then we need to compile in the authentication support.
#

my $need_auth = check_for_authentication(\%services);

print STDERR Dumper(\%services) if $dump_parsed;

while (my($service, $modules) = each %services)
{
    if(has_funcdefs($modules)) {
        write_service_stubs($service, $modules, $output_dir, $need_auth->{$service},$available_type_table);
    }
}





sub setup_impl_data
{
    my($impl_module_base, $module, $ext) = @_;
    
    my $imod;
    if ($impl_module_base)
    {
        $imod = sprintf $impl_module_base, $module->module_name;
    }
    else
    {
        $imod = $module->module_name . "Impl";
    }
    my $ifile = $imod;
    $ifile =~ s,::,/,g; #convert perl module separators to /
    $ifile =~ s,\.,/,g; #convert py module separators to /
    $ifile .= $ext;
    return $imod, $ifile;
}

# Given one more more modules that implement a service, write a single
# psgi, client and service stub for the service, and one impl stub per module.
# 
# The service stubs include a mapping from the function name in a module
# to the impl module for that function.

sub write_service_stubs
{
    my($service, $modules, $output_dir, $need_auth, $available_type_table) = @_;
    
    my $tmpl = Template->new( { OUTPUT_PATH => $output_dir,
                                ABSOLUTE => 1,
                                });

    my %service_options;
    my %module_impl_file;
    my %module_info;

    my @modules;
    
    for my $module_ent (@$modules)
    {
        my($module, $type_info, $type_table) = @$module_ent;

        # print Dumper($module);

        my($imod, $ifile) = setup_impl_data($impl_module_base, $module, ".pm");
        my($pymod, $pyfile) = setup_impl_data($py_impl_module, $module, ".py");

        $module_info{$module->module_name} = { module => $imod, file => $ifile,
                                               pymodule => $pymod, pyfile => $pyfile
                                              };
    
        $service_options{$_} = 1 foreach @{$module->options};
        
        my $data = compute_module_data($module, $imod, $ifile, $pymod, $pyfile, $type_info, $type_table,$available_type_table);
        
        push(@modules, $data);
    }

    my $client_package_name = $client_module || ($service . "Client");
    my $server_package_name = $service_module || ($service . "Server");
    my $python_server_name = $py_server_module || ($service . "Server");

    my $client_package_file = $client_package_name;
    $client_package_file =~ s,::,/,g;
    $client_package_file .= ".pm";
    make_path($output_dir . "/" . dirname($client_package_file));

    my $server_package_file = $server_package_name;
    $server_package_file =~ s,::,/,g;
    $server_package_file .= ".pm";
    make_path($output_dir . "/" . dirname($server_package_file));

    my $python_server_file = $python_server_name;
    $python_server_file =~ s,\.,/,g;
    $python_server_file =~ s,::,/,g;
    $python_server_file .= ".py";
    make_path($output_dir . "/" . dirname($python_server_file));
    
    my $js_file = $js_module || ($service . "Client");
    $js_file .= ".js";

    my $py_file = $py_module || ($service . "Client");
    $py_file =~ s,\.,/,g;
    $py_file .= ".py";

    # don't create psgi if not requested
    # my $psgi_file = $psgi || ($service . ".psgi");
    my $psgi_file = $psgi;
    
    my $vars = {
        client_package_name => $client_package_name,
        server_package_name => $server_package_name,
        python_server_name => $python_server_name,
        service_name => $service,
        modules => \@modules,
        module_info => \%module_info,
        service_options => \%service_options,
        default_service_url => $default_service_url,
        authenticated => $need_auth,
        psgi_file => $psgi_file,
    };
#    print Dumper($vars);

    my $tmpl_dir = Bio::KBase::KIDL::KBT->install_path;

    $tmpl->process("$tmpl_dir/js.tt", $vars, $js_file) || die Template->error;
    $tmpl->process("$tmpl_dir/python_client.tt", $vars, $py_file) || die Template->error;
    $tmpl->process("$tmpl_dir/python_server.tt", $vars, $python_server_file) || die Template->error;
    $tmpl->process("$tmpl_dir/client_stub.tt", $vars, $client_package_file) || die Template->error;
    $tmpl->process("$tmpl_dir/server_stub.tt", $vars, $server_package_file) || die Template->error;
    if ($psgi_file)
    {
        $tmpl->process("$tmpl_dir/psgi_stub.tt", $vars, $psgi_file) || die Template->error;
    }

    if ($test_script)
    {
        $tmpl->process("$tmpl_dir/client_test.tt", $vars, $test_script) || die Template->error;
    }

    for my $module_ent (@$modules)
    {
        my($module, $type_info) = @$module_ent;

        my($ifile, $imod) = @{$module_info{$module->module_name}}{'file', 'module'};
        my($pyfile, $pymod) = @{$module_info{$module->module_name}}{'pyfile', 'pymodule'};

        write_module_stubs($service, $imod, $ifile, $module, $type_info, $vars, $output_dir);
        write_module_stubs($service, $pymod, $pyfile, $module, $type_info, 
                           $vars, $output_dir, 'python_impl.tt');
        write_scripts($scripts_dir, $module, $vars, $output_dir);
    }
}

sub parse_old_client
{
    my($mod_file) = @_;
    
    my %saved_stub;
    my $saved_header;
    my $saved_const;
    my $saved_cls_hdr;
    
    if (open(my $fh, "<", "$output_dir/$mod_file"))
    {
        #
        # Collect old client implementation code.
        #
        my $cur_rtn;
        my $cur_hdr;
        my $cur_const;
        my $cur_clshdr;
        while (<$fh>)
        {
            if (/^\s*\#BEGIN\s+(\S+)/)
            {
                $cur_rtn = $1;
            }
            elsif (/^\s*\#END\s+(\S+)/)
            {
                undef $cur_rtn;
            }
            elsif ($cur_rtn)
            {
                $saved_stub{$cur_rtn} .= $_;
            }
            elsif (/^\s*\#BEGIN_HEADER\s*$/)
            {
                $cur_hdr = 1;
            }
            elsif (/^\s*\#END_HEADER\s*$/)
            {
                $cur_hdr = 0;
            }
            elsif (/^\s*\#BEGIN_CLASS_HEADER\s*$/)
            {
                $cur_clshdr = 1;
            }
            elsif (/^\s*\#END_CLASS_HEADER\s*$/)
            {
                $cur_clshdr = 0;
            }
            elsif (/^\s*\#BEGIN_CONSTRUCTOR\s*$/)
            {
                $cur_const = 1;
            }
            elsif (/^\s*\#END_CONSTRUCTOR\s*$/)
            {
                $cur_const = 0;
            }
            elsif ($cur_hdr)
            {
                $saved_header .= $_;
            }
            elsif ($cur_clshdr)
            {
                $saved_cls_hdr .= $_;
            }
            elsif ($cur_const)
            {
                $saved_const .= $_;
            }
        }
        close($fh);
    }
    return $saved_header, $saved_cls_hdr, $saved_const, \%saved_stub;
}

sub get_type_names
{
    my($type) = @_;
    
    my $typedef = $type->as_string();
    $typedef =~ m/^\s*(\w+)\s*(?:[<{].+)?$/; #this is a bit hacky, maybe add a method to each type - should ask Bob
    my $baretype = $1;
    return $typedef, $baretype;
}

sub compute_module_data
{
    my($module, $impl_module_name, $impl_module_file, $py_impl_mod, 
       $py_impl_file, $type_info, $type_table, $available_type_table) = @_;
    
    my $doc = $module->comment;
    $doc =~ s/^\s*\*\s?//mg;
    
    my($saved_header, $saved_cls_hdr, $saved_const, $saved_stub) = 
                parse_old_client($impl_module_file);
    my %saved_stub = %$saved_stub;
    
    my($py_saved_header, $py_saved_clshdr, $py_saved_const, $py_saved_stub) = 
                parse_old_client($py_impl_file);
    my %py_saved_stub = %$py_saved_stub;
    
    my $methods = [];

    my $vars = {
        impl_package_name => $impl_module_name,
        py_impl_package_name => $py_impl_mod,
        module_name => $module->module_name,
        module => $module,
        module_doc => $doc,
        methods => $methods,
        types => $type_info,
        available_types => $available_type_table,
        module_header => $saved_header,
        module_constructor => $saved_const,
        py_module_header => $py_saved_header,
        py_module_class_header => $py_saved_clshdr,
        py_module_constructor => $py_saved_const,
    };

    for my $comp (@{$module->module_components})
    {
        next unless $comp->isa('Bio::KBase::KIDL::KBT::Funcdef');

        my $params = $comp->parameters;
        my @args;
        my @arg_types;
        my @arg_validators;
        my %ncount;
        my @param_dat;
        my @return_dat;
    
        for my $i (0..$#$params)
        {
            my $p = $params->[$i];
    
            my $name;
            if ($p->{name})
            {
                $name = $p->{name};
            }
            else
            {
                #
                # if we didn't pass in a name, and if
                # this parameter is a typedef, use the type name.
                #
                if (ref($p->{type}) && $p->{type}->can('alias_type'))
                {
                    $name = $p->{type}->name;
                }
                else
                {
                    $name = "arg_" . ($i + 1);
                }
            }
            push(@args, $name);
            $ncount{$name}++;
        }

        #
        # Scan args for duplicates and disambiguate.
        #
        for my $argi (0..$#args)
        {
            if ($ncount{$args[$argi]} > 1)
            {
                $args[$argi] .= "_" . ($argi + 1);
            }
        }
        #
        # Generate english type descriptions.
        #
        my %types_seen;
        my $typenames = [];
        
        my @english;
        
        for my $argi (0..$#args)
        {
            my $name = $args[$argi];
            my $p = $params->[$argi];
            my $type = $p->{type};
            my $p_src_module = $type->{module};
            my $eng = $type->english(1);
            my $tn = $type->subtypes(\%types_seen);
            
            # print "arg $argi $type subtypes @$tn\n";
            
            push(@$typenames, @$tn);
            push(@english, "\$$name is $eng");
            my $perl_var = "\$$name";
            
            my($typedef, $baretype) = get_type_names($type);
            
            my $validator = $type->get_validation_routine($perl_var);
            push(@arg_validators, $validator);
            $param_dat[$argi] = {
                index => ($argi + 1),
                name => $name,
                perl_var => '$' . $name,
                english => $eng,
                type => $type,
                validator => $validator,
                typedef => $typedef,
                baretype => $baretype,
            };
        
        }

        my $args = join(", ", @args);
        my $arg_vars = join(", ", map { "\$$_" } @args);

        my $returns = $comp->return_type;
    
        my @rets;

        if (@$returns == 1)
        {
            my $p = $returns->[0];
            my $name = $p->{name} // "return";
            push(@rets, $name);
            my $tn = $p->{type}->subtypes(\%types_seen);
            push(@$typenames, @$tn);
            my $eng = $p->{type}->english(1);
            push(@english, "\$$name is $eng");
        }
        else
        {
            for my $i (0..$#$returns)
            {
                my $p = $returns->[$i];
                my $name = $p->{name} // "return_" . ($i + 1);
                push(@rets, $name);
                my $tn = $p->{type}->subtypes(\%types_seen);
                push(@$typenames, @$tn);
                my $eng = $p->{type}->english(1);
                push(@english, "\$$name is $eng");
            }
        }

        for my $i (0..$#$returns)
        {
            my $name = $rets[$i];
            my $perl_var = "\$$name";
            my $type = $returns->[$i]->{type};
            my $validator = $type->get_validation_routine($perl_var);
            my($typedef, $baretype) = get_type_names($type);
            $return_dat[$i] = {
                name => $name,
                perl_var => '$' . $name,
                english => $english[$i],
                type => $type,
                validator => $validator,
                typedef => $typedef,
                baretype => $baretype,
            };
        }

        my $rets = join(", ", @rets);
        my $ret_vars = join(", ", map { "\$$_" } @rets);

        for my $tn (@$typenames)
        {
            my $src_module = $tn->[0]; my $tname = $tn->[1];
            print 'lookup of '.$src_module.".".$tname."\n";
            if($src_module eq $module->module_name) {
                my $type = $type_table->{$tname};
                if (!defined($type))
                {
                    die "Type $tname is not defined in module " . $module->module_name . "\n";
                }
                push(@english, "$tname is " . $type->alias_type->english(1));
            } else {
                my $type = $available_type_table->{$src_module}->{$tname};
                if (!defined($type))
                {
                    print Dumper($available_type_table)."\n";
                    die "Type $tname is not defined in module " . $src_module . "\n";
                }
                push(@english, "$tname is " . $type->alias_type->english(1) . " from Module $src_module");
            }
        }
        
        my $doc = $comp->comment;
        $doc =~ s/^\s*\*\s?//mg;
    
        chomp @english;
    
        my $meth = {
            name => $comp->name,
            arg_doc => [grep { !/^\s*$/ } @english],
            doc => $doc,
            args => $args,
            arg_vars => $arg_vars,
            arg_types => \@arg_types,
            arg_validators => \@arg_validators,
            params => \@param_dat,
            returns => \@return_dat,
            
            rets => $rets,
            ret_vars => $ret_vars,
            arg_count => scalar @args,
            ret_count => scalar @rets,
            user_code => $saved_stub{$comp->name},
            py_user_code => $py_saved_stub{$comp->name},
            authentication => $comp->authentication,
        };
        push(@$methods, $meth);
    }
    
    return $vars;
}

sub get_module_script_info
{
    my($module, $vars, $output_dir) = @_;
    
    my($my_module) = grep { $_->{module_name} eq $module->module_name } @{$vars->{modules}};
    
    my $tmpl = Template->new( { OUTPUT_PATH => $output_dir,
                                ABSOLUTE => 1,
                                });

    my $tmpl_dir = Bio::KBase::KIDL::KBT->install_path;
    
    return $my_module, $tmpl, $tmpl_dir;
}

sub write_module_stubs
{
    my($service, $impl_module_name, $impl_module_file, $module, $type_info, $vars, $output_dir, $template) = @_;
    
    if (!(defined $template)) 
    {
        $template = 'impl_stub.tt';
    }
    
    my($my_module, $tmpl, $tmpl_dir) = get_module_script_info($module, $vars, $output_dir);
    
    my $impl_file = "$output_dir/$impl_module_file";
    make_path(dirname($impl_file), { verbose => 1 });
    if (-f $impl_file)
    {
        my $ts = strftime("%Y-%m-%d-%H-%M-%S", localtime);
        my $bak = "$impl_file.bak-$ts";
        rename($impl_file, $bak);
    }

    my $mvars = {
                  %$vars,
                  module => $my_module,
                 };

    open(IM, ">", $impl_file) or die "Cannot write $impl_file: $!";
    $tmpl->process("$tmpl_dir/$template", $mvars, \*IM) || die Template->error;
    close(IM);
}
    
sub write_scripts
{
    my($scripts_dir, $module, $vars, $output_dir) = @_;

    my($my_module, $tmpl, $tmpl_dir) = get_module_script_info($module, $vars, $output_dir);

    if ($scripts_dir)
    {
        for my $method (@{$my_module->{methods}})
        {
            my %d = %$vars;
            $d{method} = $method;
            my $name = $method->{name};

	    if (0)
	    {
		# don't write the api scripts since they confuse people

		my $fh;
		if (!open($fh, ">", "$scripts_dir/$name.pl"))
		{
		    die "Cannot write $scripts_dir/$name.pl: $!";
		}
	    
		$tmpl->process("$tmpl_dir/api_script.tt", \%d, $fh) || die Template->error;
	    }

            #
            # Determine if the signature of this method allows the creation of a simple script.
            #
            my $ok = 1;
            for my $param (@{$method->{params}})
            {
                #
                # Resolve type.
                #
                my $type = $param->{type};
                while ($type->can('alias_type'))
                {
                    $type = $type->alias_type;
                }
                if (!$type->isa('Bio::KBase::KIDL::KBT::Scalar'))
                {
                    $ok = 0;
                    last;
                }
            }
            if ($ok)
            {
                my $fh;
		my $file = "$scripts_dir/simple_$name.pl";
		if (-f $file)
		{
		    warn "Not overwriting existing file $file\n";
		}
		else
		{
		    if (!open($fh, ">", $file))
		    {
			die "Cannot write $file: $!";
		    }
	    
		    $tmpl->process("$tmpl_dir/simple_cmd.tt", \%d, $fh) || die Template->error;
		    close($fh);
		}
            }
        }
    }
}

sub assemble_types
{
    my($parser) = @_;

    my $all_types = {};
    for my $mod_name (@{$parser->modulelist()})
    {
        my $types = [];
    
        for my $type (@{$parser->moduletypes($mod_name)})
        {
            my $name = $type->name;
            my $ref = $type->alias_type;
            my $eng = $ref->english(0);
            push(@$types, {
                name => $name,
                module=> $mod_name,
                ref => $ref,
                english => $eng,
                comment => $type->comment,
                });
        }
        
        $all_types->{$mod_name} = $types;
    }
    return $all_types;
}

sub check_for_authentication
{
    my($services) = @_;
    my $out = {};

 SVC:
    while (my($service, $modules) = each %$services)
    {
        $out->{$service} = 0;
        for my $module_ent (@$modules)
        {
            my($module, $type_info, $type_table) = @$module_ent;
            for my $comp (@{$module->module_components})
            {
                next unless $comp->isa('Bio::KBase::KIDL::KBT::Funcdef');
                if ($comp->authentication eq 'required' || $comp->authentication eq 'optional')
                {
                    $out->{$service} = 1;
                    next SVC;
                }
            }
        }
    }
    return $out;
}


#  given a reference to a list of module objects as parsed by the type compiler, return 1 if any one of the
#  modules contains a function definition, 0 otherwise.  This method allows us to check if funcdefs exist
#  before creating all the stubs.
sub has_funcdefs
{
    my($modules) = @_;
    #print "------\n";
    #print Dumper($modules)."\n";
    #exit(1);
    
    # is there a better way than just looping over everything??
    foreach my $module (@{$modules})
    {
        foreach my $component (@{$module->[0]->module_components})
        {
            return 1 if ($component->isa('Bio::KBase::KIDL::KBT::Funcdef'));
        }
    }
    return 0;
}




__DATA__
