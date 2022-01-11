use utf8;

package Koha::Plugin::Com::BibLibre::EasyPayments::TransactionSchema;

=head1 NAME

Koha::Plugin::Com::BibLibre::EasyPayments::TransactionSchema

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<koha_plugin_com_biblibre_easypayments_transactions>

=cut

__PACKAGE__->table("koha_plugin_com_biblibre_easypayments_transactions");

=head1 ACCESSORS

=head2 transaction_id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 accountline_id

  data_type: 'integer'
  is_nullable: 1

=head2 borrowernumber

  data_type: 'integer'
  is_nullable: 1

=head2 accountlines_ids

  data_type: 'mediumtext'
  is_nullable: 1

=head2 amount

  data_type: 'decimal'
  is_nullable: 1
  size: [28,6]

=head2 authorization

  data_type: 'char'
  is_nullable: 1
  size: 32

=head2 payment_id

  data_type: 'char'
  is_nullable: 1
  size: 32

=head2 updated

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: current_timestamp
  is_nullable: 0

=head2 provider_error

  data_type: 'mediumtext'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
    "transaction_id",
    { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
    "accountline_id",
    { data_type => "integer", is_nullable => 1 },
    "borrowernumber",
    { data_type => "integer", is_nullable => 1 },
    "accountlines_ids",
    { data_type => "mediumtext", is_nullable => 1 },
    "amount",
    { data_type => "decimal", is_nullable => 1, size => [ 28, 6 ] },
    "authorization",
    { data_type => "char", is_nullable => 1, size => 32 },
    "payment_id",
    { data_type => "char", is_nullable => 1, size => 32 },
    "updated",
    {
        data_type                 => "timestamp",
        datetime_undef_if_invalid => 1,
        default_value             => \"current_timestamp",
        is_nullable               => 0,
    },
    "provider_error",
    { data_type => "mediumtext", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</transaction_id>

=back

=cut

__PACKAGE__->set_primary_key("transaction_id");

sub koha_object_class {
    'Koha::Plugin::Com::BibLibre::EasyPayments::Transaction';
}

sub koha_objects_class {
    'Koha::Plugin::Com::BibLibre::EasyPayments::Transactions';
}

1;
