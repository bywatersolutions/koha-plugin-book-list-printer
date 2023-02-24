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

    my $filename = 'report-step2-adoc.tt';
    my $template = $self->get_template({file => $filename});

    my $display_by = $cgi->param('display_by');

    my $order_by
        = $display_by eq 'title'   ? 'biblio.title'
        : $display_by eq 'author'  ? 'biblio.author'
        : $display_by eq 'subject' ? 'subject'
        :                                         'title';

    my @locations = $cgi->multi_param('location');

    my $search_params = {};
    $search_params->{permanent_location} = \@locations if @locations;

    my $items = Koha::Items->search($search_params, {prefetch => 'biblio', order_by => {-asc => $order_by}});

    $template->param(items => $items, locations => \@locations, displayby => $display_by);

    $self->output_html($template->output());
}

#my $schema = Koha::Database->new->schema;
#$schema->storage->debug(1);

1;
