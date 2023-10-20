package Koha::Plugin::Com::BibLibre::EasyPayments::Transaction;

use Modern::Perl;
use Koha::Account::Lines;
use Koha::Patrons;
use Koha::Schema;
use Koha::Plugin::Com::BibLibre::EasyPayments;
use Koha::Plugin::Com::BibLibre::EasyPayments::TransactionSchema;

use base qw(Koha::Object);

BEGIN {
    Koha::Database->schema->register_class( TransactionSchema =>
          'Koha::Plugin::Com::BibLibre::EasyPayments::TransactionSchema' );
}

=head1 NAME

Koha::Plugin::Com::BibLibre::EasyPayments::Transaction

=head1 API


=head2 External methods

=head3 pay_accountlines

=cut

sub pay_accountlines {
    my $self = shift;

    my @accountline_ids = split( ' ', $self->accountlines_ids );
    my $lines           = Koha::Account::Lines->search(
        { accountlines_id => { 'in' => \@accountline_ids } } )->as_list;

    my $borrowernumber = $self->borrowernumber;
    my $borrower        = Koha::Patrons->find($borrowernumber);
    my $account = Koha::Account->new( { patron_id => $borrowernumber } );
    my $accountline_id = $account->pay(
        {
            amount     => $self->amount,
            note       => "Easy Payment " . $self->payment_id,
            library_id => $borrower->branchcode,
            lines => $lines,    # Arrayref of Koha::Account::Line objects to pay
        }
    );

    if ( ref $accountline_id eq 'HASH' ) {
        $accountline_id = $accountline_id->{payment_id};
    }

    # Link payment to dibs_transactions and set finished timestamp
    $self->update( { accountline_id => $accountline_id,
                     finished =>  \'NOW()' } );

    # Renew any items as required
    for my $line ( @{$lines} ) {
        if ( !$line->itemnumber ) {
            next;
        }

        # Skip if renewal not required
        if ( $line->status ne 'UNRETURNED' ) {
            next;
        }

        if (
            !Koha::Checkouts->find(
                {
                    itemnumber     => $line->itemnumber,
                    borrowernumber => $line->borrowernumber
                }
            )
          )
        {
            next;
        }

        my ( $renew_ok, $error ) =
          C4::Circulation::CanBookBeRenewed( $line->borrowernumber,
            $line->itemnumber );
        if ($renew_ok) {
            C4::Circulation::AddRenewal( $line->borrowernumber,
                $line->itemnumber );
        }
    }

    return $self;
}


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
