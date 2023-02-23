package Koha::Plugin::Com::ByWaterSolutions::BookListPrinter;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::Items;

use Cwd qw(abs_path);
use Data::Dumper;

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

    unless ($cgi->param('output')) {
        $self->report_step1();
    } else {
        $self->report_step2();
    }
}

sub report_step1 {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({file => 'report-step1.tt'});

    $self->output_html($template->output());
}

sub report_step2 {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $filename = 'report-step2-html.tt';
    my $template = $self->get_template({file => $filename});

    my $order_by
        = $cgi->param('displayby') eq 'title'   ? 'biblio.title'
        : $cgi->param('displayby') eq 'author'  ? 'biblio.author'
        : $cgi->param('displayby') eq 'subject' ? 'subject'
        :                                         'title';

    my $items = Koha::Items->search({}, {prefetch => 'biblio', order_by => {-asc => $order_by}});

    $template->param(items => $items);

    $self->output_html($template->output());
}


1;
