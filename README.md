# Introduction
This Koha plugin enables a library to accept online payments from patrons using either the Easy payments platform or the Netaxept platform.
See https://tech.dibspayment.com/easy or https://shop.nets.eu/web/partners/get-started

# Installing
To set up the Koha plugin system you must first make some changes to your install.

* Change `<enable_plugins>0<enable_plugins>` to `<enable_plugins>1</enable_plugins>` in your koha-conf.xml file
* Confirm that the path to `<pluginsdir>` exists, is correct, and is writable by the web server
* Restart your webserver

# Easy configuration
* Create an Easy test account (https://portal.dibspayment.eu/registration)
* Log in to the admin interface (https://portal.dibspayment.eu/)
* Select `Company` from the menu on the left
* Select `Integration` under `Company`
* Copy the secret keys (not the checkout keys) for the Live and Test environment

# Netaxept configuration
* Apply for a test account at Nets (https://shop.nets.eu/web/partners/get-started)
* You will recieve a MerchantId, password for the admin interface (https://test.epayment.nets.eu/Admin/Default.aspx) and a secret API-key.

# Plugin configuration
* Make sure that Koha's OPACBaseURL system preference is correctly set
* Select preferred payment provider in the plugin configuration page.
* Énter the 3-letter currency code (eg. SEK).
* Enable test mode if in test environment.
* Enter the merchantId (if Netaxept) and secret keys.


# API routes
The plugin requires that its API routes are added to Koha.
* Enable the plugin
* Restart the webserver after installing the plugin

# Testing
Testing information can be found at (https://tech.dibspayment.com/easy/test-information)
