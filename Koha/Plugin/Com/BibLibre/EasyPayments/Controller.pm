package Koha::Plugin::Com::BibLibre::EasyPayments::Controller;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use C4::Context;
use C4::Circulation;
use C4::Auth;
use Koha::Account::Lines;
use Koha::Acquisition::Currencies;
use Koha::Patrons;
use Koha::Plugin::Com::BibLibre::EasyPayments;
use Koha::Plugin::Com::BibLibre::EasyPayments::CGIMojo;

use LWP::UserAgent ();
use JSON qw(encode_json);

=head1 API
=head2 Class Methods
=head3 Method to process callback
=cut

sub callback {
    my $c      = shift->openapi->valid_input or return;
    my $body   = $c->req->json;
    my $result = $c->render( status => 200, text => '' );

    if ( $body->{event} ne 'payment.checkout.completed' ) {
        return $result;
    }
    my $paymentHandler = Koha::Plugin::Com::BibLibre::EasyPayments->new;

    my $koha_transaction_id = $body->{data}->{order}->{reference};
    if ( !$koha_transaction_id ) {
        warn 'orderid missing';
        return $result;
    }

    my $authkey = $c->req->headers->authorization;
    if ( !$authkey ) {
        warn 'authkey missing';
        return $result;
    }

    my $transaction =
      Koha::Plugin::Com::BibLibre::EasyPayments::Transactions->find(
        {
            transaction_id => $koha_transaction_id
        }
      );
    my $borrowernumber = $transaction->borrowernumber;
    my $payment_id     = $transaction->payment_id;

    if ( $authkey ne $transaction->authorization ) {
        warn 'wrong authkey';
        return $result;
    }

    my $ua = LWP::UserAgent->new;

    # Decimal separators are not allowed in Easy.
    # The last two digits of a number are considered to be the decimals.

    my $datastring = encode_json(
        {
            amount     => int( $transaction->amount * 100 ),
            orderItems => $body->{data}->{order}->{orderItems}
        }
    );
    my ( $easy_server, $secret_key, $correct_key );
    if ( $paymentHandler->retrieve_data('testMode') ) {
        $easy_server = 'test.api.dibspayment.eu';
        $correct_key =
          ( $secret_key = $paymentHandler->retrieve_data('test_key') ) =~
          s/test-secret-key-//;
    }
    else {
        $easy_server = 'api.dibspayment.eu';
        $correct_key =
          ( $secret_key = $paymentHandler->retrieve_data('live_key') ) =~
          s/live-secret-key-//;
    }
    if ( !$correct_key ) {
        warn 'Secret key has the wrong prefix';
        return $result;
    }
    my $easy_url =
      URI->new_abs( "v1/payments/$payment_id/charges", "https://$easy_server" )
      ->as_string;
    my $response = $ua->post(
        $easy_url,
        Authorization  => $secret_key,
        'Content-Type' => 'application/json',
        Content        => $datastring
    );

    if ( $response->code != 201 ) {
        warn $response->code . ': ' . $response->content;
        return $result;
    }

    my @accountline_ids = split( ' ', $transaction->accountlines_ids );
    my $borrower        = Koha::Patrons->find($borrowernumber);
    my $lines           = Koha::Account::Lines->search(
        { accountlines_id => { 'in' => \@accountline_ids } } )->as_list;
    my $account = Koha::Account->new( { patron_id => $borrowernumber } );
    my $accountline_id = $account->pay(
        {
            amount     => $transaction->amount,
            note       => "Easy Payment $payment_id",
            library_id => $borrower->branchcode,
            lines => $lines,    # Arrayref of Koha::Account::Line objects to pay
        }
    );

    if ( ref $accountline_id eq 'HASH' ) {
        $accountline_id = $accountline_id->{payment_id};
    }

    # Link payment to dibs_transactions
    $transaction->update( { accountline_id => $accountline_id } );

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
    return $result;
}

=head3 Method to display terms
=cut

sub terms {
    my $c = shift->openapi->valid_input or return;
    my $paymentHandler = Koha::Plugin::Com::BibLibre::EasyPayments->new;
    my $cgi = Koha::Plugin::Com::BibLibre::EasyPayments::CGIMojo->new($c);
    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name =>
              $paymentHandler->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 1,
            is_plugin       => 1,
        }
    );
    $template->param( easy_message => $paymentHandler->retrieve_data('terms') );
    return $c->render( status => 200, text => $template->output );
}

1;
