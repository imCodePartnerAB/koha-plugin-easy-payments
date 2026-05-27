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
use Koha::Logger;
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
    my $c         = shift->openapi->valid_input or return;
    my $body      = $c->req->json;
    my $result    = $c->render( status => 200, text => '' );
    my $logger    = Koha::Logger->get;
    my $logprefix = "Easy Payments Plugin: ";

    my $event = $body->{event};
    $logger->debug($logprefix . "Callback called with event " . $body->{event});
    if ( $event ne 'payment.charge.created.v2' &&
         $event ne 'payment.checkout.completed') {
        return $result;
    }
    my $paymentMethod = $body->{data}->{paymentMethod} // '';
    my $paymentType = $body->{data}->{paymentType} // '';
    $logger->debug($logprefix . "Callback called with paymentMethod: $paymentMethod, paymentType: $paymentType");

    my $paymentHandler = Koha::Plugin::Com::BibLibre::EasyPayments->new;

    my $conf = $paymentHandler->active_config;

    # Using payment_id instead of transaction reference, since
    # transaction reference is not returned by payment.charge.created.v2
    my $payment_id = $body->{data}->{paymentId};
    if ( !$payment_id ) {
        warn 'paymentId missing';
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
            payment_id => $payment_id
        }
      );

    $logger->debug($logprefix . "Callback: found transaction id: " . $transaction->transaction_id . ", amount: " . $transaction->amount );

    my $borrowernumber = $transaction->borrowernumber;

    if ( $authkey ne $transaction->authorization ) {
        warn 'wrong authkey';
        return $result;
    }

    my $ua = LWP::UserAgent->new( timeout => 8 );

    # Decimal separators are not allowed in Easy.
    # The last two digits of a number are considered to be the decimals.

    my $datastring = encode_json(
        {
            amount     => int( $transaction->amount * 100 ),
            orderItems => $body->{data}->{order}->{orderItems}
        }
    );

    # Swish payments are not reserved, they are directly charged,
    # so calling the charge api route will result in an error (Cannot overcharge payment)
    # This is not a big deal, as it does not prevent payment.
    # However, if we wanted to have a cleaner workflow, we should either:
    #  - add a payment_method column to koha_plugin_com_biblibre_easypayments_transactions
    # or:
    #  - query /v1/payments/{paymentId} to get paymentMethod
    #    ( see https://developer.nexigroup.com/nexi-checkout/en-EU/api/payment-v1/#v1-payments-paymentid-get )
    # so we know on payment.checkout.completed that this was a swish payment and that we don't need to call the charge api route.
    # (payment.charge.created.v2 returns paymentMethod, payment.checkout.completed does not)
    if ($event eq 'payment.checkout.completed') {
        $logger->debug($logprefix . "Callback calling v1/payments/$payment_id/charges");
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
    }
    if (!$transaction->finished) {
        my $pay_params = {
            payment_type => $conf->{payment_type},
            api_payment_method => $paymentMethod,
            api_payment_type => $paymentType
        };

        $logger->debug($logprefix . "Callback: paying accountlines");
        $transaction->pay_accountlines( $pay_params );
    } else {
        $logger->debug($logprefix . "Callback: transaction already finished");
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
    my $conf = $paymentHandler->active_config;

    $template->param( easy_message => $conf->('easy_terms') );
    return $c->render( status => 200, text => $template->output );
}

1;
