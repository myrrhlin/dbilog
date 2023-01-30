package DBI::Log;

use 5.006;
no strict;
no warnings;
use DBI;
use Time::HiRes;

our $VERSION = "0.10";
our %opts = (
    file => $file,
    trace => 0,
    timing => 0,
    replace_placeholders => 1,
    fh => undef,
    exclude => undef,
);

my $orig_execute = \&DBI::st::execute;
*DBI::st::execute = sub {
    my ($sth, @args) = @_;
    my $log = pre_query("execute", $sth->{Database}, $sth, $sth->{Statement}, \@args);
    my $retval = $orig_execute->($sth, @args);
    post_query($log);
    return $retval;
};

my $orig_selectall_arrayref = \&DBI::db::selectall_arrayref;
*DBI::db::selectall_arrayref = sub {
    my ($dbh, $query, $yup, @args) = @_;
    my $log = pre_query("selectall_arrayref", $dbh, undef, $query, \@args);
    my $retval = $orig_selectall_arrayref->($dbh, $query, $yup, @args);
    post_query($log);
    return $retval;
};

my $orig_selectcol_arrayref = \&DBI::db::selectcol_arrayref;
*DBI::db::selectcol_arrayref = sub {
    my ($dbh, $query, $yup, @args) = @_;
    my $log = pre_query("selectcol_arrayref", $dbh, undef, $query, \@args);
    my $retval = $orig_selectcol_arrayref->($dbh, $query, $yup, @args);
    post_query($log);
    return $retval;
};

my $orig_selectall_hashref = \&DBI::db::selectall_hashref;
*DBI::db::selectall_hashref = sub {
    my ($dbh, $query, $yup, @args) = @_;
    my $log = pre_query("selectall_hashref", $dbh, undef, $query, \@args);
    my $retval = $orig_selectall_hashref->($dbh, $query, $yup, @args);
    post_query($log);
    return $retval;
};

my $orig_selectrow_arrayref = \&DBI::db::selectrow_arrayref;
*DBI::db::selectrow_arrayref = sub {
    my ($dbh, $query, $yup, @args) = @_;
    my $log = pre_query("selectrow_arrayref", $dbh, $sth, $query, \@args);
    my $retval = $orig_selectrow_arrayref->($dbh, $query, $yup, @args);
    post_query($log);
    return $retval;
};

my $orig_selectrow_array = \&DBI::db::selectrow_array;
*DBI::db::selectrow_array = sub {
    my ($dbh, $query, $yup, @args) = @_;
    my $log = pre_query("selectrow_array", $dbh, undef, $query, \@args);
    my $retval = $orig_selectrow_array->($dbh, $query, $yup, @args);
    post_query($log);
    return $retval;
};

my $orig_selectrow_hashref = \&DBI::db::selectrow_hashref;
*DBI::db::selectrow_hashref = sub {
    my ($dbh, $query, $yup, @args) = @_;
    my $log = pre_query("selectrow_hashref", $dbh, undef, $query, \@args);
    my $retval = $orig_selectrow_hashref->($dbh, $query, $yup, @args);
    post_query($log);
    return $retval;
};

my $orig_do = \&DBI::db::do;
*DBI::db::do = sub {
    my ($dbh, $query, $yup, @args) = @_;
    my $log = pre_query("do", $dbh, undef, $query, \@args);
    my $retval = $orig_do->($dbh, $query, $yup, @args);
    post_query($log);
    return $retval;
};


sub import {
    my ($package, %args) = @_;
    for my $key (keys %args) {
        $opts{$key} = $args{$key};
    }
    if (!$opts{file}) {
        $opts{fh} = \*STDERR;
    }
    else {
        my $file2 = $opts{file};
        if ($file2 =~ m{^~/}) {
            my $home = $ENV{HOME} || (getpwuid($<))[7];
            $file2 =~ s{^~/}{$home/};
        }
        open $opts{fh}, ">>", $file2 or die "Can't open $opts{file}: $!";
    }
}

sub pre_query {
    my ($name, $dbh, $sth, $query, $args) = @_;
    my $log = {};
    my $mcount = 0;

    # Some DBI functions are composed of other DBI functions, so make sure we
    # are only logging the top level one. For example $dbh->do() will call
    # $dbh->execute() internally, so we need to make sure a DBI::Log function
    # logs the $dbh->do() and not the internal $dbh->execute(). If multiple
    # functions were called, we return and flag this log entry to be skipped in
    # the post_query() part.
    for (my $i = 0; my @caller = caller($i); $i++) {
        my ($package, $file, $line, $sub) = @caller;
        if ($package eq "DBI::Log") {
            $mcount++;
            if ($mcount > 1) {
                $log->{skip} = 1;
                return $log;
            }
        }
    }
    my @callers;
    for (my $i = 0; my @caller = caller($i); $i++) {
        push @callers, \@caller;
    }

    # Order the call stack based on the highest level calls first, then the
    # lower level calls. Once you reach a package that is excluded, do not show
    # any more lines in the stack trace. By default, it will exclude anything
    # past the DBI::Log package, but if user provides an exclude option, it will
    # stop there.
    my @filtered_callers;
    CALLER: for my $caller (reverse @callers) {
        my ($package, $file, $line, $sub) = @$caller;
        if ($package eq "DBI::Log") {
            last CALLER;
        }
        if ($opts{exclude}) {
            for my $item (@{$opts{exclude}}) {
                if ($package =~ /^$item(::|$)/) {
                    last CALLER;
                }
            }
        }
        push @filtered_callers, $caller;

    }
    if (!$opts{trace}) {
        @filtered_callers = ($filtered_callers[-1]);
    }

    my $stack = "";
    for my $caller (@filtered_callers) {
        my ($package, $file, $line, $sub) = @$caller;
        my $short_sub = $sub;
        $short_sub =~ s/.*:://;
        $short_sub = $name if $sub =~ /^DBI::Log::__ANON__/;
        $stack .= "-- $short_sub $file $line\n";
    }

    if (ref($query) && ref($query) eq "DBI::st") {
        $sth = $query;
        $query = $query->{Statement};
    }

    if ($dbh && $opts{replace_placeholders}) {
        # When you use $sth->bind_param(1, "value") the params can be found in
        # $sth->{ParamValues} and they override arguments sent in to
        # $sth->execute()

        my @args_copy = @$args;
        my %values;
        if ($sth && $sth->{ParamValues}) {
            %values = %{$sth->{ParamValues}};
        }
        for my $key (keys %values) {
            if (defined $key && $key =~ /^\d+$/) {
                $args_copy[$key - 1] = $values{$key};
            }
        }

        for my $i (0 .. @args_copy - 1) {
            my $value = $args_copy[$i];
            $value = $dbh->quote($value);
            $query =~ s{\?}{$value}e;
        }
    }

    $query =~ s/^\s*\n|\s*$//g;
    $info = "-- " . scalar(localtime()) . "\n";
    print {$opts{fh}} "$info$stack$query\n";
    $log->{time1} = Time::HiRes::time();
    return $log;
}

sub post_query {
    my ($log) = @_;
    return if $log->{skip};
    if ($opts{timing}) {
        $log->{time2} = Time::HiRes::time();
        my $diff = sprintf '%.3f', $log->{time2} - $log->{time1};
        print {$opts{fh}} "-- ${diff}s\n";
    }
    print {$opts{fh}} "\n";
}

1;

__END__

=encoding utf8

=head1 NAME

DBI::Log - Log all DBI queries

=head1 SYNOPSIS

    use DBI::Log;

or

    perl -MDBI::Log path/to/script.pl

=head1 DESCRIPTION

You can use this module to log all queries that are made with DBI. You can
include it in your script with `use DBI::Log` or use the C<-M> option for
C<perl> to avoid changing your code at all.

By default, it will send output to C<STDERR>, which is useful for command line 
scripts and for CGI scripts since STDERR will appear in the error log.

You can control where output goes, and various other behaviour, by setting
the options documented below.

=head1 OPTIONS

Options can be set on the C<use DBI::Log>` line when loading the module:

    use DBI::Log timing => 1, file => "/tmp/querylog.sql";

or passed to C<-M> e.g.:

    perl -M'DBI::Log timing => 1' path/to/script.pl

The following options are available:

=over 4

=item C<file>

Set the C<file> option to send query logs to the named file instead of STDERR.

    use DBI::Log file => "~/querylog.sql";

Each query in the log is prepended with the date and the place in the code where
it was run from. You can add a full stack trace by setting the trace option.

=item C<trace>

Include a stack trace with each query, so you can see where the code which
performed the query was called from:

    use DBI::Log trace => 1;

=item C<timing>

If you want timing information about how long the queries took to run add the
C<timing> option.

    use DBI::Log timing => 1;

=item C<exclude>

If you want to exclude function calls from within certain package(s) appearing 
in the stack trace from C<trace>, you can use the exclude option like this:

    use DBI::Log exclude => ["DBIx::Class"];

It will exclude any package starting with that name, for example
C<DBIx::Class::ResultSet> and C<DBI::Log> are excluded by default.

=item C<format>

By default the log is formatted as SQL, so if you look at it in an editor, 
it might be syntax highlighted. Additional information about the query
is added as SQL comments.

This is what the output may look like:

    -- Fri Sep 11 17:31:18 2015
    -- execute t/test.t 18
    CREATE TABLE foo (a INT, b INT)

    -- Fri Sep 11 17:31:18 2015
    -- do t/test.t 21
    INSERT INTO foo VALUES ('1', '2')

    -- Fri Sep 11 17:31:18 2015
    -- selectcol_arrayref t/test.t 24
    SELECT * FROM foo

    -- Fri Sep 11 17:31:18 2015
    -- do t/test.t 27
    -- (eval) t/test.t 27
    INSERT INTO bar VALUES ('1', '2')

You can instead set C<format> to C<json> if you want JSON-format output -
this will then return L<newline-delimited JSON|https://jsonlines.org/>
output - which you can process with L<jq|https://stedolan.github.io/jq/>
or C<logstash> or various other tools more easily than the SQL text format.

=item C<replace_placeholders>

By default, this module replaces placeholders in the query with the values
- either provided in a call to execute() or bound beforehand - but this
behaviour can be disabled by setting C<replace_placeholders> to false:

    use DBI::Log replace_placeholders => 0;

This may be useful if you're doing later processing on the log, e.g. parsing
it and grouping by queries, and want all executions of the same query to
look alike without the values.

=back

=head1 Why? / SEE ALSO

There is a built-in way to log with DBI, which can be enabled with
C<DBI->trace(1)>, but the output is not particulary easy to read through
nor does it give you much idea where the queries are run from.

L<DBIx::Class> provides facilities via the C<DBIC_TRACE> env var or setting 
C<$class->storage->debug(1);>, and even more powerful facilities by setting
C<debugobj()>, but if you have a codebase which mixes DBIx::Class
queries with direct DBI queries, you won't be capturing all queries.

L<DBIx::Class::UnicornLogger>, L<DBIx::Class::Storage::Debug::PrettyTrace>
and other similar options may be useful if you use DBIx::Class exclusively.


=head1 METACPAN

L<https://metacpan.org/pod/DBI::Log>

=head1 REPOSITORY

L<https://github.com/zorgnax/dbilog>

=head1 AUTHOR

Jacob Gelbman, E<lt>gelbman@gmail.comE<gt>

=head1 CONTRIBUTORS

=over

=item * Árpád Szász, E<lt>arpad.szasz@plenum.roE<gt>

=item * Pavel Serikov

=item * David Precious (BIGPRESH) - E<lt>davidp@preshweb.co.ukE<gt>

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015 by Jacob Gelbman

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.18.2 or, at your option,
any later version of Perl 5 you may have available.

=cut

