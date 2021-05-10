package Koha::Plugin::Com::BibLibre::EasyPayments::CGIMojo;

use Modern::Perl;

use parent qw(CGI);

our $mojo_app;

sub new {
    my ( $self, $app ) = @_;
    $mojo_app = $app;
    $self->SUPER::new;
}

sub cookie {
    my $self = shift;
    if ( $mojo_app && scalar @_ == 1 && $mojo_app->cookie(@_) ) {
        return $mojo_app->cookie(@_);
    }
    $self->SUPER::cookie(@_);
}

1;
