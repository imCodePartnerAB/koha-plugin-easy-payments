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

    my $conf = $paymentHandler->active_config;

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

    my $easy_url =
      URI->new_abs( "v1/payments/$payment_id/charges", "https://" . $conf->{easy_server} )
      ->as_string;
    my $response = $ua->post(
        $easy_url,
        Authorization  => $conf->{easy_key},
        'Content-Type' => 'application/json',
        Content        => $datastring
    );

    if ( $response->code != 201 ) {
        warn $response->code . ': ' . $response->content;
        return $result;
    }

    my $pay_params = { payment_type => $conf->{payment_type} };
    $transaction->pay_accountlines( $pay_params );

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
    my $conf = $paymentHandler->active_config;

    $template->param( easy_message => $conf->('easy_terms') );
    return $c->render( status => 200, text => $template->output );
}

1;
