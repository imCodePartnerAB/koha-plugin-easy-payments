package Koha::Plugin::Com::BibLibre::EasyPayments::Transaction;

use Modern::Perl;
use Koha::Schema;
use Koha::Plugin::Com::BibLibre::EasyPayments::TransactionSchema;

use base qw(Koha::Object);

BEGIN {
    Koha::Schema->register_class( TransactionSchema =>
          'Koha::Plugin::Com::BibLibre::EasyPayments::TransactionSchema' );
    Koha::Database->schema( { new => 1 } );
}

=head1 NAME

Koha::Plugin::Com::BibLibre::EasyPayments::Transaction

=head1 API

=head2 Internal methods

=head3 _new_from_dbic

=cut

sub _new_from_dbic {
    my ( $class, $dbic_row ) = @_;
    my $self = {};

    # DBIC result row
    $self->{_result} = $dbic_row;

    if ( !$class->_type() ) {
        croak('No _type found! Koha::Object must be subclassed!');
    }

    if (
        ref( $self->{_result} ) ne
        'Koha::Plugin::Com::BibLibre::EasyPayments::' . $class->_type() )
    {
        croak(  'DBIC result _type '
              . ref( $self->{_result} )
              . q{ isn't of the _type }
              . $class->_type() );
    }

    bless( $self, $class );

}

=head3 _type

=cut

sub _type {
    return 'TransactionSchema';
}

1;
