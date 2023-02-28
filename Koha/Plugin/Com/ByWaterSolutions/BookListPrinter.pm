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

    $template->param(asciidoctor_installed => is_cmd_installed('asciidoctor-pdf'));

    $self->output_html($template->output());
}

sub report_step2 {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $display_by = $cgi->param('display_by');

    my $order_by
        = $display_by eq 'title'   ? 'biblio.title'
        : $display_by eq 'author'  ? 'biblio.author'
        : $display_by eq 'subject' ? 'subject'
        :                            'title';

    my @locations  = $cgi->multi_param('location');
    my $branchcode = $cgi->param('branchcode');

    my ($afh, $adoc_file)   = tempfile(undef, SUFFIX => '.adoc');
    my ($sfh, $status_file) = tempfile(undef, SUFFIX => '.yml');
    warn "ADOC: $adoc_file";
    warn "STATUS: $status_file";

    my $pid = fork;

    # Parent outputs status page and exits
    if ($pid != 0) {
        my $template = $self->get_template({file => 'report-step2-status.tt'});
        $template->param(status_file => $status_file);
        $self->output_html($template->output());
        exit;
    }

    my $status = {
        pid       => $$,
        status    => 'Gathering data',
        pid       => $pid,
        adoc_file => $adoc_file,
        updated   => dt_from_string()->iso8601,
    };
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    # Child gets to work
    my $template = $self->get_template({file => 'report-step2-adoc.tt'});

    my $search_params = {};
    $search_params->{permanent_location} = \@locations if @locations;
    $search_params->{homebranch}         = $branchcode if $branchcode;

    my $items = Koha::Items->search($search_params, {prefetch => 'biblio', order_by => {-asc => $order_by}});

    $status->{count}   = $items->count;
    $status->{status}  = 'Generating ASCIIDoc';
    $status->{updated} = dt_from_string()->iso8601;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    $template->param(items => $items, locations => \@locations, homebranch => $branchcode, displayby => $display_by);
    $template->{TEMPLATE}->process($template->filename, $template->{VARS}, $afh) || die "Template process failed: ",
        $template->{TEMPLATE}->error();

    $status->{status}  = 'Generating PDF';
    $status->{updated} = dt_from_string()->iso8601;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    my $pdf_file = $adoc_file;
    $pdf_file =~ s/adoc$/pdf/;

    my $output = qx(asciidoctor-pdf $adoc_file);
    $status->{status}      = 'Finished';
    $status->{updated}     = dt_from_string()->iso8601;
    $status->{pdf_file}    = $pdf_file;
    $status->{adoc_output} = $output;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);
}

sub report_status {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $file = $cgi->param('status');
    warn "FILE: $file";
    my $data = LoadFile($file);

    my $filename = $data->{pdf_file} || $data->{adoc_file};
    my $bytes = ( stat $filename )[7];
    $data->{current_file_size} = $bytes;

    $self->output_html(to_json($data));
}

sub report_download {
    warn "REPORT DOWNLOAD";
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $file = $cgi->param('status');
    warn "FILE: $file";
    my $data = LoadFile($file);
    warn Data::Dumper::Dumper($data);

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

    unlink $data->{adoc_file};
    unlink $data->{pdf_file};
}

sub is_cmd_installed {
    my $check = `sh -c 'command -v $_[0]'`;
    return $check;
}

#my $schema = Koha::Database->new->schema;
#$schema->storage->debug(1);

1;
