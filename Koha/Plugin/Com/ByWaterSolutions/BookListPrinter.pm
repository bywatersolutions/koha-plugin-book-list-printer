package Koha::Plugin::Com::ByWaterSolutions::BookListPrinter;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Items;

use Cwd qw(abs_path);
use Data::Dumper;
use File::Temp qw(tempfile tempdir);
use JSON       qw(to_json);
use Try::Tiny;
use YAML       qw(DumpFile LoadFile);

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
    my ( $class, $args ) = @_;

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
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( $cgi->param('output') ) {
        $self->report_step2();
    }
    elsif ( $cgi->param('download') ) {
        $self->report_download();
    }
    elsif ( $cgi->param('status') ) {
        $self->report_status();
    }
    else {
        $self->report_step1();
    }
}

sub report_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'report-step1.tt' } );

    $template->param(
        wkhtmltopdf_installed => is_cmd_installed('wkhtmltopdf') );

    $self->output_html( $template->output() );
}

sub report_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $display_by = $cgi->param('display_by');

    my $order_by =
        $display_by eq 'title'   ? 'biblio.title'
      : $display_by eq 'author'  ? 'biblio.author'
      : $display_by eq 'subject' ? 'subject'
      :                            'title';

    my @locations  = $cgi->multi_param('location');
    my $branchcode = $cgi->param('branchcode');

    my ( $afh, $html_file )   = tempfile( undef, SUFFIX => '.html' );
    my ( $sfh, $status_file ) = tempfile( undef, SUFFIX => '.yml' );
    warn "ADOC: $html_file";
    warn "STATUS: $status_file";

    my $pid = fork;

    # Parent outputs status page and exits
    if ( $pid != 0 ) {
        my $template =
          $self->get_template( { file => 'report-step2-status.tt' } );
        $template->param( status_file => $status_file );
        $self->output_html( $template->output() );
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
    DumpFile( $status_file, $status );
    warn Data::Dumper::Dumper($status);

    my $template = $self->get_template( { file => 'report-step2-html.tt' } );

    my $search_params = {};
    $search_params->{permanent_location} = \@locations if @locations;
    $search_params->{homebranch}         = $branchcode if $branchcode;

    my $items = Koha::Items->search( $search_params,
        { prefetch => 'biblio', order_by => { -asc => $order_by } } );

    $status->{count}   = $items->count;
    $status->{status}  = 'Generating HTML';
    $status->{updated} = dt_from_string()->iso8601;
    DumpFile( $status_file, $status );
    warn Data::Dumper::Dumper($status);

    $template->param(
        items      => $items,
        locations  => \@locations,
        homebranch => $branchcode,
        displayby  => $display_by
    );
    my $ok = $template->{TEMPLATE}->process( $template->filename, $template->{VARS}, $afh );
    $status->{error} = "Template process failed: " .
      $template->{TEMPLATE}->error() unless $ok;

    $status->{status}  = 'Generating PDF';
    $status->{updated} = dt_from_string()->iso8601;
    DumpFile( $status_file, $status );
    warn Data::Dumper::Dumper($status);

    my $pdf_file = $html_file;
    $pdf_file =~ s/html$/pdf/;

    my $command = qq{/usr/local/bin/wkhtmltopdf --page-size letter  --header-left "Page [page] of [toPage]" --header-right "Date: [date]" --header-spacing 3 --header-font-size 10 --footer-spacing 4 --footer-left "" --footer-right '' --footer-font-size 10 --margin-top 10mm --margin-bottom 10mm --margin-left 10mm --margin-right 10mm $html_file $pdf_file 2>&1};
    my $output = qx($command);
    my $rc = $?;
    $rc = $rc >> 8 unless ($rc == -1);
    $status->{error} = $output if $rc;

    $status->{status}      = 'Finished';
    $status->{updated}     = dt_from_string()->iso8601;
    $status->{pdf_file}    = $pdf_file;
    $status->{html_output} = $output;
    DumpFile( $status_file, $status );
    warn Data::Dumper::Dumper($status);
}

sub report_status {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $file = $cgi->param('status');
    warn "FILE: $file";
    my $data = LoadFile($file);

    my $filename = $data->{pdf_file} || $data->{html_file};
    my $bytes    = ( stat $filename )[7];
    $data->{current_file_size} = $bytes;

    $self->output_html( to_json($data) );
}

sub report_download {
    warn "REPORT DOWNLOAD";
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $file = $cgi->param('status');
    warn "FILE: $file";
    my $data = LoadFile($file);
    warn Data::Dumper::Dumper($data);

    my $filename = $data->{pdf_file};
    warn "PDF FILE: $filename";

    my $bytes = ( stat $filename )[7];

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

    unlink $data->{html_file};
    unlink $data->{pdf_file};
}

sub is_cmd_installed {
    my $check = `sh -c 'command -v /usr/local/bin/$_[0]'`;
    return $check;
}

sub cronjob_nightly {
    my ( $self ) = @_;
    warn "Koha::Plugin::Com::ByWaterSolutions::BookListPrinter::cronjob_nightly";

    my $dbh = C4::Context->dbh;

    my $delete_sth = $dbh->prepare(q{DELETE FROM plugin_book_list_printer_subjects WHERE biblionumber = ?});
    my $insert_sth = $dbh->prepare(q{INSERT INTO plugin_book_list_printer_subjects VALUES ( ?, ?, ? )});

    my $biblios = Koha::Biblios->search();
    while ( my $biblio = $biblios->next() ) {
        warn "WORKING ON BIBLIO " . $biblio->id;
        my @subjects; # We want to limit to only 3 subjects per bib

        my $rec;
        try {
            $rec = $biblio->metadata->record;
        } catch {
            warn "ERROR: BAD RECORD";
            next;
        };
        next unless $rec;

        # First, look for a first 655
        if ( my $f = $rec->field('655') ) {
            my @fields;
            push( @fields, $f->subfield('a') ) if $f->subfield('a');
            push( @fields, $f->subfield('2') ) if $f->subfield('2');
            my $s = join(' - ', @fields );
            warn "FOUND SUBJECT $s";
            push( @subjects, $s ) if @fields;
        }

        # Next, fill the subjects list with 650's
        my @f = $rec->field('650');
        foreach my $f ( @f ) {
            next if scalar @subjects >= 3;

            my @fields;

            push( @fields, $f->subfield('a') ) if $f->subfield('a');
            push( @fields, $f->subfield('x') ) if $f->subfield('x');
            push( @fields, $f->subfield('2') ) if $f->subfield('2');
            my $s = join(' - ', @fields );
            warn "FOUND SUBJECT $s";
            push( @subjects, $s ) if @fields;
        }

        if ( @subjects ) {
            $delete_sth->execute( $biblio->id );
            my $i = 0;
            foreach my $s ( @subjects ) {
                $insert_sth->execute( $biblio->id, $i, $s );
                $i++;
            }
        }
    }
}

sub install {
    my ( $self, $args ) = @_;

    return C4::Context->dbh->do(q{
        CREATE TABLE `plugin_book_list_printer_subjects` (
            `biblionumber` INT(11) NOT NULL,
            `order` INT(11) NOT NULL DEFAULT '0',
            `subject` VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
            KEY `bnidx` (`biblionumber`,`order`),
            CONSTRAINT `bfk_borrowers` FOREIGN KEY (`biblionumber`) REFERENCES `biblio` (`biblionumber`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB;
    });
}

#my $schema = Koha::Database->new->schema;
#$schema->storage->debug(1);

1;
