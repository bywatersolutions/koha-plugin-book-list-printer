package Koha::Plugin::Com::ByWaterSolutions::BookListPrinter;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Items;

use Array::Utils qw(:all);
use Cwd          qw(abs_path);
use Data::Dumper;
use File::Temp qw(tempfile tempdir);
use JSON       qw(to_json);
use Try::Tiny;
use YAML qw(DumpFile LoadFile);

our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'Book List Printer',
    author          => 'Kyle M Hall',
    date_authored   => '2023-02-23',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Generate pages of books for printing and distribution.',
};

sub new {
    my ($class, $args) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub report {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    if ($cgi->param('output')) {
        $self->report_step2();
    } elsif ($cgi->param('download')) {
        $self->report_download();
    } elsif ($cgi->param('status')) {
        $self->report_status();
    } else {
        $self->report_step1();
    }
}

sub report_step1 {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({file => 'report-step1.tt'});

    $template->param(wkhtmltopdf_installed => is_cmd_installed('wkhtmltopdf'));

    $self->output_html($template->output());
}

sub report_step2 {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    #my $logger = Koha::Logger->get({ interface => 'intranet'}, 1);
    #$logger->warn("TEST");

    my $display_by = $cgi->param('display_by');

    my @locations  = $cgi->multi_param('location');
    my @itemtypes  = $cgi->multi_param('itemtype');
    my $branchcode = $cgi->param('branchcode');

    my ($afh, $html_file)   = tempfile(undef, SUFFIX => '.html');
    my ($sfh, $status_file) = tempfile(undef, SUFFIX => '.yml');
    warn "HTML: $html_file";
    warn "STATUS: $status_file";

    my $pid = fork;

    # Parent outputs status page and exits
    if ($pid != 0) {
        my $template = $self->get_template({file => 'report-step2-status.tt'});
        $template->param(status_file => $status_file);
        $self->output_html($template->output());
        exit;
    }

    # Child gets to work
    my $status = {
        pid       => $$,
        status    => 'Gathering data',
        pid       => $pid,
        html_file => $html_file,
        updated   => dt_from_string()->iso8601,
    };
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    my $template = $self->get_template({file => 'report-step2-html.tt'});

    my $items;

    if ($display_by =~ /^subject/) {
        my $tag = $display_by eq 'subject650' ? '650' : '655';

        my @parameters;

        my $query = q{
                SELECT plugin_book_list_printer_subjects.*
                FROM plugin_book_list_printer_subjects
                LEFT JOIN biblio USING ( biblionumber )
                LEFT JOIN biblioitems USING ( biblionumber )
                LEFT JOIN items USING ( biblionumber )
                WHERE tag = ?
            };
        push(@parameters, $tag);

        if (@itemtypes) {
            my $in_string = join(',', map {"\"$_\""} @itemtypes);
            $query .= qq{
                AND (
                    biblioitems.itemtype IN ( $in_string ) 
                    OR
                    items.itype IN ( $in_string )
                )
            };
        }

        if (@locations) {
            my $in_string = join(',', map {"\"$_\""} @locations);
            $query .= qq{
                AND items.location IN ( $in_string )
            };
        }

        if ($branchcode) {
            $query .= q{
                AND homebranch = ?
            };
            push(@parameters, $branchcode);
        }

        $query .= q{
            GROUP BY subject, biblionumber ORDER BY subject, biblio.author, REGEXP_REPLACE(biblio.title, "^(The|An|A)[[:space:]]+", "")
        };

        warn "QUERY: " . Data::Dumper::Dumper($query);
        warn "PARAMS: " . Data::Dumper::Dumper(@parameters);
        my $sth = C4::Context->dbh->prepare($query);
        $sth->execute(@parameters);

        my @items;
        while (my $s = $sth->fetchrow_hashref) {
            $s->{biblio} = Koha::Biblios->find($s->{biblionumber});

            if (@itemtypes) {
                my $biblio = $s->{biblio};
                my @itypes = $biblio->items->get_column('itype');
                my @isect  = intersect(@itypes, @itemtypes);
                next unless @isect;
            }

            push(@items, $s);
        }
        $items = \@items;
    } else {
        my $search_params = {};
        $search_params->{permanent_location} = \@locations if @locations;
        $search_params->{homebranch}         = $branchcode if $branchcode;
        $search_params->{itype}              = \@itemtypes if @itemtypes;

        my $order_by
            = $display_by eq 'title'  ? \'REGEXP_REPLACE(biblio.title, "^(The|An|A)[[:space:]]+", "")'
            : $display_by eq 'author' ? {-asc => 'biblio.author'}
            :                           \'REGEXP_REPLACE(biblio.title, "^(The|An|A)[[:space:]]+", "")';

        my @p = ($search_params, {prefetch => {'biblio' => 'biblio_metadatas'}, order_by => $order_by});
        warn "SEARCH PARAMS: " . Data::Dumper::Dumper(\@p);
        $items = Koha::Items->search(@p);
        warn "AS QUERY: " . Data::Dumper::Dumper($items->_resultset->as_query);

        $status->{count} = $items->count;
    }

    $status->{status}  = 'Generating HTML';
    $status->{updated} = dt_from_string()->iso8601;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    $template->param(items => $items, locations => \@locations, homebranch => $branchcode, displayby => $display_by);
    my $ok = $template->{TEMPLATE}->process($template->filename, $template->{VARS}, $afh);
    $status->{error} = "Template process failed: " . $template->{TEMPLATE}->error() unless $ok;

    $status->{status}  = 'Generating PDF';
    $status->{updated} = dt_from_string()->iso8601;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    my $pdf_file = $html_file;
    $pdf_file =~ s/html$/pdf/;

    my $command
        = qq{/usr/local/bin/wkhtmltopdf --page-size letter  --header-left "Page [page] of [toPage]" --header-right "Date: [date]" --header-spacing 3 --header-font-size 10 --footer-spacing 4 --footer-left "" --footer-right '' --footer-font-size 10 --margin-top 10mm --margin-bottom 10mm --margin-left 10mm --margin-right 10mm $html_file $pdf_file 2>&1};
    my $output = qx($command);
    my $rc     = $?;
    $rc = $rc >> 8 unless ($rc == -1);
    $status->{error} = $output if $rc;

    $status->{status}      = 'Finished';
    $status->{updated}     = dt_from_string()->iso8601;
    $status->{pdf_file}    = $pdf_file;
    $status->{html_file}   = $html_file;
    $status->{html_output} = $output;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);
}

sub report_status {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $file = $cgi->param('status');
    warn "FILE: $file";
    my $data = LoadFile($file);

    my $filename = $data->{pdf_file} || $data->{html_file};
    my $bytes    = (stat $filename)[7];
    $data->{current_file_size} = $bytes;

    $self->output_html(to_json($data));
}

sub report_download {
    warn "REPORT DOWNLOAD";
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $type = $cgi->param('type');

    my $file = $cgi->param('status');
    warn "FILE: $file";
    my $data = LoadFile($file);
    warn Data::Dumper::Dumper($data);

    if ($type eq 'pdf') {
        my $filename = $data->{pdf_file};
        warn "PDF FILE: $filename";

        my $bytes = (stat $filename)[7];

        print $cgi->header(
            -attachment => "list.pdf",
            -type       => 'application/pdf',

            #-Content_Disposition => "attachment; filename=list.pdf",
            -Content_Length => "$bytes"
        );

        open FILE, "< $filename" or die "can't open : $!";
        binmode FILE;
        local $/ = \10240;
        while (<FILE>) {
            print $_;
        }
        close FILE;

        unlink $data->{pdf_file};
    } elsif ($type eq 'html') {
        my $filename = $data->{html_file};
        warn "HTML FILE: $filename";

        my $bytes = (stat $filename)[7];

        print $cgi->header(
            -attachment => "list.html",
            -type       => 'text/html',

            #-Content_Disposition => "attachment; filename=list.pdf",
            -Content_Length => "$bytes"
        );

        open FILE, "< $filename" or die "can't open : $!";
        binmode FILE;
        local $/ = \10240;
        while (<FILE>) {
            print $_;
        }
        close FILE;

        unlink $data->{html_file};
    }

}

sub is_cmd_installed {
    my $check = `sh -c 'command -v /usr/local/bin/$_[0]'`;
    return $check;
}

sub cronjob_nightly {
    my ($self) = @_;
    warn "Koha::Plugin::Com::ByWaterSolutions::BookListPrinter::cronjob_nightly";

    my $dbh = C4::Context->dbh;

    my $delete_sth = $dbh->prepare(q{DELETE FROM plugin_book_list_printer_subjects WHERE biblionumber = ?});
    my $insert_sth = $dbh->prepare(q{INSERT INTO plugin_book_list_printer_subjects VALUES ( ?, ?, ?, ? )});

    my $biblios = Koha::Biblios->search();
    while (my $biblio = $biblios->next()) {
        warn "WORKING ON BIBLIO " . $biblio->id;
        my @subjects;    # We want to limit to only 3 subjects per bib

        my $rec;
        try {
            $rec = $biblio->metadata->record;
        } catch {
            warn "ERROR: BAD RECORD";
            next;
        };
        next unless $rec;

        # First, look for a first 655
        if (my $f = $rec->field('655')) {
            my @fields;
            push(@fields, $f->subfield('a')) if $f->subfield('a');
            my $s = join(' - ', @fields);
            warn "FOUND SUBJECT $s";
            push(@subjects, {subject => $s, tag => '655'}) if @fields;
        }

        # Next, fill the subjects list with 650's
        my @f = $rec->field('650');
        foreach my $f (@f) {
            next if scalar @subjects >= 3;

            my @fields;

            push(@fields, $f->subfield('a')) if $f->subfield('a');
            push(@fields, $f->subfield('x')) if $f->subfield('x');
            my $s = join(' - ', @fields);
            warn "FOUND SUBJECT $s";
            push(@subjects, {subject => $s, tag => '650'}) if @fields;
        }

        if (@subjects) {
            $delete_sth->execute($biblio->id);
            my $i = 0;
            foreach my $s (@subjects) {
                $insert_sth->execute($biblio->id, $i, $s->{tag}, $s->{subject});
                $i++;
            }
        }
    }
}

sub install {
    my ($self, $args) = @_;

    return C4::Context->dbh->do(q{
        CREATE TABLE `plugin_book_list_printer_subjects` (
            `biblionumber` INT(11) NOT NULL,
            `order` INT(11) NOT NULL DEFAULT '0',
            `tag` VARCHAR(3),
            `subject` VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
            KEY `bnidx` (`biblionumber`,`order`, `tag`),
            CONSTRAINT `bfk_borrowers` FOREIGN KEY (`biblionumber`) REFERENCES `biblio` (`biblionumber`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB;
    });
}

#my $schema = Koha::Database->new->schema;
#$schema->storage->debug(1);

1;
