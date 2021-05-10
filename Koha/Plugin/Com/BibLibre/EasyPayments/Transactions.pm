package Koha::Plugin::Com::BibLibre::EasyPayments::Transactions;

use Modern::Perl;
use Koha::Plugin::Com::BibLibre::EasyPayments::Transaction;

use base qw(Koha::Objects);

=head1 NAME

Koha::Plugin::Com::BibLibre::EasyPayments::Transactions

=head1 API

=head2 Internal methods

=head3 _type

=cut

sub _type {
    return 'TransactionSchema';
}

=head3 object_class

=cut

sub object_class {
    return 'Koha::Plugin::Com::BibLibre::EasyPayments::Transaction';
}

1;
