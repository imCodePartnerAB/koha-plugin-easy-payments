package Koha::Plugin::Com::BibLibre::EasyPayments;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Auth qw( get_template_and_user );
use C4::Languages qw( getlanguage );
use Koha::Account::Lines;
use Koha::Acquisition::Currencies;
use Koha::Patrons;
use Koha::Plugin::Com::BibLibre::EasyPayments::Transactions;

use LWP::UserAgent ();
use JSON           ();
use UUID;
use XML::Simple;
use Data::Dumper::Concise;

## Here we set our plugin version
our $VERSION = '00.00.08';

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Easy Payments Plugin',
    author          => 'Kevin Carnes',
    date_authored   => '2019-07-01',
    date_updated    => '2024-03-28',
    minimum_version => '19.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin implements online payments using '
      . 'Easy payments platform. https://tech.dibspayment.com/easy'
      . ' and Netaxept platform. https://shop.nets.eu/web/partners ',
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

    # Make the plugin name consistent with selected provider
    if ($self->retrieve_data('payment_provider')) {
        if ($self->retrieve_data('payment_provider') eq 'easy') {
            $self->{metadata}->{name} = 'Nets Easy';
        }
        elsif ($self->retrieve_data('payment_provider') eq 'netaxept') {
            $self->{metadata}->{name} = 'Netaxept';
        }
    }

    Koha::Plugin::Com::BibLibre::EasyPayments::TransactionSchema->table(
        $self->get_qualified_table_name('transactions') );

    return $self;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    if ( !$self->retrieve_data('enable_opac_payments') ) {
        return;
    }

    my $conf = $self->active_config;
    unless ( $conf->{config_ok} ) {
        warn "Easy payment plugin configuration not valid";
        return;
    }

    if ( $conf->{payment_provider} eq 'easy' && $self->retrieve_data('enable_api_selftest') ) {
        my $callback_url = URI->new_abs(
            'api/v1/contrib/' . $self->api_namespace . '/callback',
            C4::Context->preference('OPACBaseURL') . '/'
        );
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

    my $conf = $self->active_config;

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


    my $payment_provider = $self->retrieve_data('payment_provider');
    if ( $payment_provider eq 'easy' ){

	    # Decimal separators are not allowed in Easy.
        #The last two digits of a number are considered to be the decimals.
        $sum = int( $sum * 100 );
    
        # Construct redirect URI
        my $accepturl = URI->new_abs(
            'cgi-bin/koha/opac-account-pay-return.pl',
            C4::Context->preference('OPACBaseURL') . '/'
        );
        $accepturl->query_form( payment_method => $self->{class} );
    
        # Construct callback URI
        my $callback_url = URI->new_abs(
            'api/v1/contrib/' . $self->api_namespace . '/callback',
            C4::Context->preference('OPACBaseURL') . '/'
        );
    
        my $terms_url = URI->new_abs(
            'api/v1/contrib/' . $self->api_namespace . '/terms',
            C4::Context->preference('OPACBaseURL') . '/'
        );
    
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
                    currency  => $conf->{currency},
                    reference => $transaction_id
                },
                checkout => {
                    integrationType => 'hostedPaymentPage',
                    returnUrl       => $accepturl->as_string,
                    termsUrl        => $terms_url->as_string,
                    merchantHandlesConsumerData => $JSON::true
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

	    my $easy_url =
	      URI->new_abs( 'v1/payments', "https://" . $conf->{easy_server} )->as_string;
	    my $response = $ua->post(
	        $easy_url,
	        Authorization  => $conf->{easy_key},
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
    elsif ( $payment_provider eq 'netaxept' ) {

    	# Decimal separators are not allowed in Netaxept.
        #The last two digits of a number are considered to be the decimals.
        $sum = int( $sum * 100 );

        # Construct redirect URI
        my $accepturl = URI->new_abs(
            'cgi-bin/koha/opac-account-pay-return.pl',
            C4::Context->preference('OPACBaseURL')
        );
        $accepturl->query_form( authorization => $authorization,
                                payment_method => $self->{class}, );

        my $language = getlanguage eq 'sv-SE' ? 'sv_SE' : 'en_GB';

        my $register_url =
          URI->new_abs( 'Netaxept/Register.aspx', "https://" . $conf->{netaxept_server} );
        my $ua = LWP::UserAgent->new;
        my %register_params = (
            merchantId => $conf->{netaxept_merchantid},
            token => $conf->{netaxept_key},
            serviceType => 'B',
            orderNumber => $transaction_id,
            currencyCode => $conf->{currency},
            amount => $sum,
            redirectUrl => $accepturl->as_string,
            language    => $language,
            orderDescription => $self->order_description($transaction),
            terminalSinglePage => $conf->{netaxept_single_page_terminal} ? 'true' : 'false',
        );
        $register_url->query_form(%register_params);
        my $response = $ua->post($register_url);

        if ( $response->code != 200 ) {
            warn $response->code . ': ' . $response->content;
            $template->param( easy_message => 'Error creating payment' );
            return $self->output_html( $template->output() );
        }
        my $register_content = eval { XMLin($response->content) };

        if ( !$register_content->{'TransactionId'} ) {
            $transaction->update({ provider_error => Dumper($register_content->{Error}) });
            warn $response->code . ': ' . $response->content;
            $template->param( easy_message => 'Error creating payment' );
            return $self->output_html( $template->output() );
        }

        $transaction->payment_id( $register_content->{'TransactionId'} )->store;

        my $terminal_url =
          URI->new_abs( 'Terminal/default.aspx', "https://" . $conf->{netaxept_server} );
        $terminal_url->query_form( merchantId => $conf->{netaxept_merchantid},
                                   transactionId => $register_content->{'TransactionId'},
                                   );
        print $cgi->redirect( $terminal_url->as_string );
        exit;
    }
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
    $template->param(
        CLASS       => $self->{'class'},
        METHOD      => scalar $self->{'cgi'}->param('method'),
        PLUGIN_PATH => $self->get_plugin_http_path(),
        PLUGIN_DIR  => $self->bundle_path(),
        LANG        => C4::Languages::getlanguage($self->{'cgi'}),
    );
    my $conf = $self->active_config;

    my $payment_provider = $conf->{'payment_provider'};
    if ( $payment_provider eq 'easy' ){
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
	        currency      => $conf->{'currency'},
	        message_value => sprintf '%.2f',
	        abs( $line->amount )
	    );

        # Check payment went through here
        my $payment_id = $cgi->param('paymentid');
        my $message;
        my $loop = 10;
        while ( $loop-- > 0 ) {
            $transaction =
              Koha::Plugin::Com::BibLibre::EasyPayments::Transactions->find(
                {
                    payment_id => $payment_id
                }
              );
            if ( !$transaction ) {
                warn "No transaction for payment $payment_id";
                $message = 'no_transaction';
                last;
            }
            if ( $transaction->borrowernumber != $borrowernumber ) {
                warn
    "Borrower $borrowernumber requested payment $payment_id for borrower "
                  . $transaction->borrowernumber;
                $message = 'another_borrower';
                last;
            }
            last if defined $transaction->accountline_id;
            sleep(2);
        }
        if ( !defined $transaction->accountline_id ) {
            warn "No payment found for payment $payment_id. Check API callback.";
            $message = 'no_payment';
        }
        if ($message) {
            $template->param(
                reload  => $cgi->url( -relative => 1, -query => 1 ),
                message => $message
            );
        }
        return $self->output_html( $template->output() );
    }
    elsif ( $payment_provider eq 'netaxept' ){

        # Netaxept req us to process the payment once user returns 

        my $payment_id = $cgi->param('transactionId');
        if (!$payment_id){
            warn "Netaxept opac_online_payment_end: no transactionId";
            $template->param(
                borrower => scalar Koha::Patrons->find($borrowernumber),
                message  => 'no_transactionId',
            );
            return $self->output_html( $template->output() );
            exit;
        }

        my $authorization = $cgi->param('authorization');
        if (!$authorization){
            warn "Netaxept opac_online_payment_end: no autorization token";
            $template->param(
                borrower => scalar Koha::Patrons->find($borrowernumber),
                message  => 'no_authorization',
            );
            return $self->output_html( $template->output() );
            exit;
        }


        my $transaction =
          Koha::Plugin::Com::BibLibre::EasyPayments::Transactions->find(
            {
                payment_id   => $payment_id,
            }
          );
        if ( $authorization ne $transaction->authorization ) {
            warn 'Netaxept opac_online_payment_end: wrong authorization token';
            $template->param(
                borrower => scalar Koha::Patrons->find($borrowernumber),
                message  => 'wrong_authorization',
            );
            return $self->output_html( $template->output() );
            exit;
        }
        $template->param( transaction_id => $transaction->transaction_id, );

        my $ok = $cgi->param('responseCode');
        if ( $ok ne 'OK' ){
                warn "Netaxept opac_online_payment_end: $ok";
                # TODO: May want to use the query call to find errormessage
                my $ua = LWP::UserAgent->new;

                my %query_params = (
                            merchantId => $conf->{netaxept_merchantid},
                            token      => $conf->{netaxept_key},
                            transactionId => $payment_id,
                            );
                my $query_url =
                    URI->new_abs( 'Netaxept/Query.aspx', "https://". $conf->{netaxept_server} );
                $query_url->query_form(%query_params);
                my $response = $ua->post($query_url);
                my $r = eval { XMLin($response->content) };
                $transaction->update( { provider_error => Dumper($r->{Error}) } );
                my $error = netaxept_process_error($r->{Error});
                $template->param(
                    borrower => scalar Koha::Patrons->find($borrowernumber),
                    message  => $error->{message},
                    action   => $error->{action},

                );
                return $self->output_html( $template->output() );
                exit;
        }


        # Process payment
        my $ua = LWP::UserAgent->new;

        my %process_params = (
            merchantId => $conf->{netaxept_merchantid},
            token      => $conf->{netaxept_key},
            operation  => 'SALE',
            transactionId => $payment_id,
            transactionAmount => int( $transaction->amount * 100 ),
            );
        my $process_url =
          URI->new_abs( 'Netaxept/Process.aspx', "https://". $conf->{netaxept_server} );
        $process_url->query_form(%process_params);
        my $response = $ua->post($process_url);

        if ( $response->code != 200 ) {
            warn 'Netaxept, process payment: ' . $response->code . ': ' . $response->content;
            $template->param( message => 'Error finishing payment' );
            return $self->output_html( $template->output() );
            exit;
        }
        my $process = eval { XMLin($response->content) };
        if ($process->{ResponseCode} ne 'OK' ){
            warn 'Netaxept, process payment ResponseCode error: ' . $process->{Error}->{Result}->{ResponseCode} . ':' .  $process->{Error}->{Result}->{ResponseText};
            $transaction->update( { provider_error => Dumper($process->{Error}) } );

            my $error = netaxept_process_error($process->{Error});
            $template->param( message => $error->{message},
                              action  => $error->{action}, );
            return $self->output_html( $template->output() );
            exit;
        }

        # Set accountlines as paid
        my $pay_params = { payment_type => $conf->{payment_type} };
        $transaction->pay_accountlines( $pay_params );

        $template->param( borrower      => scalar Koha::Patrons->find($borrowernumber),
                      message       => 'valid_payment',
                      message_value => sprintf('%.2f', $transaction->amount),
                      currency      => $conf->{'currency'},
                     );
    }

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
                payment_type => scalar $cgi->param('payment_type'),
                easy_live_key => scalar $cgi->param('easy_live_key'),
                easy_test_key => scalar $cgi->param('easy_test_key'),
                testMode => scalar $cgi->param('testMode'),
                easy_terms    => scalar $cgi->param('easy_terms'),
                payment_provider => scalar $cgi->param('payment_provider'),
                netaxept_live_merchantid => scalar $cgi->param('netaxept_live_merchantid'),
                netaxept_test_merchantid => scalar $cgi->param('netaxept_test_merchantid'),
                netaxept_live_key => scalar $cgi->param('netaxept_live_key'),
                netaxept_test_key => scalar $cgi->param('netaxept_test_key'),
                netaxept_single_page_terminal => scalar $cgi->param('netaxept_single_page_terminal'),
                enable_api_selftest => scalar $cgi->param('enable_api_selftest'),
            }
        );
        $self->go_home();
    }
    else {
        my $template = $self->get_template( { file => 'configure.tt' } );
        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments =>
              $self->retrieve_data('enable_opac_payments'),
            currency => $self->retrieve_data('currency'),
            payment_type => $self->retrieve_data('payment_type'),
            easy_live_key => $self->retrieve_data('easy_live_key'),
            easy_test_key => $self->retrieve_data('easy_test_key'),
            testMode => $self->retrieve_data('testMode'),
            easy_terms    => $self->retrieve_data('easy_terms'),
            payment_provider => $self->retrieve_data('payment_provider'),
            netaxept_live_merchantid => $self->retrieve_data('netaxept_live_merchantid'),
            netaxept_test_merchantid => $self->retrieve_data('netaxept_test_merchantid'),
            netaxept_live_key => $self->retrieve_data('netaxept_live_key'),
            netaxept_test_key => $self->retrieve_data('netaxept_test_key'),
            netaxept_single_page_terminal => $self->retrieve_data('netaxept_single_page_terminal'),
            enable_api_selftest => $self->retrieve_data('enable_api_selftest'),
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
            `provider_error` mediumtext,
            `finished` datetime,
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

sub active_config {
    my ($self) = @_;
    
    my $conf;
    
    # General conf
    $conf->{enable_opac_payments} = $self->retrieve_data('enable_opac_payments');
    $conf->{payment_provider} = $self->retrieve_data('payment_provider');
    $conf->{testMode} = $self->retrieve_data('testMode');
    $conf->{currency} = $self->retrieve_data('currency');
    $conf->{payment_type} = $self->retrieve_data('payment_type');

    if ( $conf->{payment_provider} eq 'easy' ) {
        my ( $easy_server, $secret_key, $correct_key );
        if ( $conf->{testMode} ) {
            $easy_server = 'test.api.dibspayment.eu';
            $correct_key = ( $secret_key = $self->retrieve_data('easy_test_key') ) =~
              s/test-secret-key-//;
        }
        else {
            $easy_server = 'api.dibspayment.eu';
            $correct_key = ( $secret_key = $self->retrieve_data('easy_live_key') ) =~
              s/live-secret-key-//;
        }
        if ( !$correct_key ) {
            warn 'Config Easy secret key has the wrong prefix';
            $conf->{config_ok} = 0;    
            return;
        }
        else {
            $conf->{easy_key} = $secret_key;
            $conf->{easy_server} = $easy_server;
        }
        $conf->{easy_terms} = $self->retrieve_data('easy_terms');
    }
    if ( $conf->{payment_provider} eq 'netaxept' ) {
        if ( $conf->{testMode} ) {
            $conf->{netaxept_merchantid} = $self->retrieve_data('netaxept_test_merchantid');
            $conf->{netaxept_key} = $self->retrieve_data('netaxept_test_key');
            $conf->{netaxept_server} = 'test.epayment.nets.eu';
        }
        else{
            $conf->{netaxept_merchantid} = $self->retrieve_data('netaxept_live_merchantid');
            $conf->{netaxept_key} = $self->retrieve_data('netaxept_live_key');
            $conf->{netaxept_server} = 'epayment.nets.eu';
        }
        if ( !$conf->{netaxept_merchantid} || !$conf->{netaxept_key} ) {
            warn 'Config Netaxept merchantid or key missing';
            $conf->{config_ok} = 0;
            return;
        }
        $conf->{netaxept_single_page_terminal} = $self->retrieve_data('netaxept_single_page_terminal');
    }
    $conf->{config_ok} = 1;

    return $conf;    
    
}

=head3 order_description

$desc = $self->order_description($transaction);

Returns a description of what fines are included in the transaction, suitable for sending to payment provider

=cut

sub order_description {
    my $self = shift;
    my ($transaction) = @_;

    my $conf = $self->active_config;

    my @accountline_ids = split( ' ', $transaction->accountlines_ids );
    my $lines           = Koha::Account::Lines->search(
        { accountlines_id => { 'in' => \@accountline_ids } } )->as_list;

    my ( $template ) = $self->get_template(
        {
            file => 'order_description.tt',
        }
    );

    $template->param(
        LINES => $lines,
        payment_provider => $conf->{payment_provider},
        TRANSACTION      => $transaction,
    );
    return $template->output;
}

sub netaxept_process_error {
    my($error) = @_;

    # ResponseCode may be under Result for some calls
    if ( !(exists $error->{ResponseCode}) && exists $error->{Result} ) {
        $error = $error->{Result};
    }

    my @canceled = ('17');
    my @refused_issuer = ('01','02','41','43','51','59','61','62','65','66','93');
    my @refused = ('03','04','05','07','08','10','14','15','19','25','30','34'
                  ,'35','36','37','37','39','52','54','57','58','60','63','68'
                  ,'79','80','C9','N0','P1','P9','T3','T8','1A');

    my $return;
    if (grep {$_ eq $error->{ResponseCode}} @canceled ) {
        $return->{message} = 'cancel';
    }
    elsif (grep {$_ eq $error->{ResponseCode}} @refused_issuer) {
        $return->{message} = 'refused';
        $return->{action} = 'contact_issuer';
    }
    elsif (grep {$_ eq $error->{ResponseCode}} @refused) {
        $return->{message} = 'refused';
        $return->{action} = 'contact_library';
    }
    else {
        $return->{message} = 'payment_failed';
        $return->{action} = 'contact_library';
    }
    return $return;

}

sub finished_transactions {
   my ($self, $param) = @_;

   my $filter;
   $filter-> {accountline_id} = { '!=', undef };
   $filter->{finished}{'>='} = $param->{from} if $param->{from};
   $filter->{finished}{'<='} = $param->{to}   if $param->{to};

   my $transactions =
     Koha::Plugin::Com::BibLibre::EasyPayments::Transactions->search(
      $filter
      )->as_list;
   return $transactions;
}

1;

