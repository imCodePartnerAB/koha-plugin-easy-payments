package Koha::Plugin::Com::BibLibre::EasyPayments;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Auth;
use Koha::Account::Lines;
use Koha::Acquisition::Currencies;
use Koha::Patrons;
use Koha::Plugin::Com::BibLibre::EasyPayments::Transactions;

use LWP::UserAgent ();
use JSON           ();
use UUID;

## Here we set our plugin version
our $VERSION = '00.00.04';

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Easy Payments Plugin',
    author          => 'Matthias Meusburger',
    date_authored   => '2019-07-01',
    date_updated    => '2021-05-17',
    minimum_version => '19.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin implements online payments using '
      . 'Easy payments platform. https://tech.dibspayment.com/easy',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    Koha::Plugin::Com::BibLibre::EasyPayments::TransactionSchema->table(
        $self->get_qualified_table_name('transactions') );

    return $self;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    if ( !$self->retrieve_data('enable_opac_payments') ) {
        return;
    }

    my $callback_url =
      URI->new_abs( 'api/v1/contrib/' . $self->api_namespace . '/callback',
        C4::Context->preference('OPACBaseURL') . '/' );
    my $ua       = LWP::UserAgent->new;
    my $response = $ua->post(
        $callback_url->as_string,
        'Content-Type' => 'application/json',
        Content        => '{"event": "test.api"}'
    );
    if ( $response->code != 200 ) {
        warn 'Easy Payment API not enabled. Please restart web server.';
        return;
    }

    return 1;
}

## Initiate the payment process
sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    # Get the borrower
    my $borrower_result = Koha::Patrons->find($borrowernumber);

    # Add the accountlines to pay off
    my @accountline_ids = $cgi->multi_param('accountline');
    my $accountlines =
      Koha::Account::Lines->search( { accountlines_id => \@accountline_ids } );

    my $sum = sprintf '%.2f', $accountlines->total_outstanding;

    # Create a transaction
    my $authorization = UUID::uuid() =~ y/-//dr;
    my $transaction =
      Koha::Plugin::Com::BibLibre::EasyPayments::Transaction->new(
        {
            borrowernumber   => $borrowernumber,
            accountlines_ids => join( ' ', $cgi->multi_param('accountline') ),
            amount           => $sum,
            authorization    => $authorization
        }
      )->store;
    my $transaction_id = $transaction->transaction_id;

    # Decimal separators are not allowed in Easy.
    #The last two digits of a number are considered to be the decimals.
    $sum = int( $sum * 100 );

    # Construct redirect URI
    my $accepturl = URI->new_abs(
        'cgi-bin/koha/opac-account-pay-return.pl?payment_method='
          . $self->{class},
        C4::Context->preference('OPACBaseURL') . '/'
    );

    # Construct callback URI
    my $callback_url =
      URI->new_abs( 'api/v1/contrib/' . $self->api_namespace . '/callback',
        C4::Context->preference('OPACBaseURL') . '/' );

    my $terms_url =
      URI->new_abs( 'api/v1/contrib/' . $self->api_namespace . '/terms',
        C4::Context->preference('OPACBaseURL') . '/' );

    my $ua         = LWP::UserAgent->new;
    my $datastring = JSON::encode_json(
        {
            order => {
                items => [
                    {
                        name             => 'Fee',
                        quantity         => 1,
                        unit             => 'x',
                        unitPrice        => $sum,
                        grossTotalAmount => $sum,
                        netTotalAmount   => $sum,
                        reference        => 'fee'
                    }
                ],
                amount    => $sum,
                currency  => $self->retrieve_data('currency'),
                reference => $transaction_id
            },
            checkout => {
                integrationType => 'hostedPaymentPage',
                returnUrl       => $accepturl->as_string,
                termsUrl        => $terms_url->as_string
            },
            notifications => {
                webhooks => [
                    {
                        eventName     => 'payment.checkout.completed',
                        url           => $callback_url->as_string,
                        authorization => $authorization
                    }
                ]
            }
        }
    );
    my ( $easy_server, $secret_key, $correct_key );
    if ( $self->retrieve_data('testMode') ) {
        $easy_server = 'test.api.dibspayment.eu';
        $correct_key = ( $secret_key = $self->retrieve_data('test_key') ) =~
          s/test-secret-key-//;
    }
    else {
        $easy_server = 'api.dibspayment.eu';
        $correct_key = ( $secret_key = $self->retrieve_data('live_key') ) =~
          s/live-secret-key-//;
    }
    if ( !$correct_key ) {
        warn 'Secret key has the wrong prefix';
        $template->param( easy_message => 'Error creating payment' );
        $self->output_html( $template->output() );
    }
    my $easy_url =
      URI->new_abs( 'v1/payments', "https://$easy_server" )->as_string;
    my $response = $ua->post(
        $easy_url,
        Authorization  => $secret_key,
        'Content-Type' => 'application/json',
        Content        => $datastring
    );
    if ( $response->code != 201 ) {
        warn $response->code . ': ' . $response->content;
        $template->param( easy_message => 'Error creating payment' );
        return $self->output_html( $template->output() );
    }
    my $json = JSON::decode_json( $response->decoded_content );
    $transaction->payment_id( $json->{paymentId} )->store;
    print $cgi->redirect( $json->{hostedPaymentPageUrl} );
    exit;
}

## Complete the payment process
sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    # Check payment went through here
    my $transaction =
      Koha::Plugin::Com::BibLibre::EasyPayments::Transactions->find(
        {
            payment_id => scalar $cgi->param('paymentid')
        }
      );
    if ( !defined $transaction->accountline_id ) {
        warn 'No payment found. Check API callback.';
        $template->param(
            borrower => scalar Koha::Patrons->find($borrowernumber),
            message  => 'no_payment'
        );
        return $self->output_html( $template->output() );
    }

    my $line =
      Koha::Account::Lines->find(
        { accountlines_id => $transaction->accountline_id } );

    $template->param(
        borrower      => scalar Koha::Patrons->find($borrowernumber),
        message       => 'valid_payment',
        currency      => $self->retrieve_data('currency'),
        message_value => sprintf '%.2f',
        abs( $line->amount )
    );

    $self->output_html( $template->output() );
}

## If your tool is complicated enough to needs it's own setting/configuration
## you will want to add a 'configure' method to your plugin like so.
## Here I am throwing all the logic into the 'configure' method, but it could
## be split up like the 'report' method is.
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( scalar $cgi->param('save') ) {
        $self->store_data(
            {
                enable_opac_payments =>
                  scalar $cgi->param('enable_opac_payments'),
                currency => scalar $cgi->param('currency'),
                live_key => scalar $cgi->param('live_key'),
                test_key => scalar $cgi->param('test_key'),
                testMode => scalar $cgi->param('testMode'),
                terms    => scalar $cgi->param('terms')
            }
        );
        $self->go_home();
    }
    else {
        my $template = $self->get_template( { file => 'configure.tt' } );
        my $apis_url = URI->new_abs(
            'api/v1/.html',
            C4::Context->preference('staffClientBaseURL') . '/'
        );
        my $callback = '/api/v1/contrib/' . $self->api_namespace . '/callback';
        my $message = 'Please restart the web server.';
        if (!$self->is_enabled) {
            $message = 'Please enable the plugin and restart the web server.';
        }

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            apis_url => $apis_url,
            callback => $callback,
            message  => $message,
            enable_opac_payments =>
              $self->retrieve_data('enable_opac_payments'),
            currency => $self->retrieve_data('currency'),
            live_key => $self->retrieve_data('live_key'),
            test_key => $self->retrieve_data('test_key'),
            testMode => $self->retrieve_data('testMode'),
            terms    => $self->retrieve_data('terms')
        );

        $self->output_html( $template->output() );
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this
## method. The installation method should always return true if the
## installation succeeded or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('transactions');

    return C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS $table (
            `transaction_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `accountline_id` INT( 11 ),
            `borrowernumber` INT( 11 ),
            `accountlines_ids` mediumtext,
            `amount` decimal(28,6),
            `authorization` CHAR( 32 ),
            `payment_id` CHAR( 32 ),
            `updated` TIMESTAMP,
            PRIMARY KEY (`transaction_id`)
        ) ENGINE = INNODB;
    " );
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = JSON::decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'easy';
}

1;

