# Introduction
This Koha plugin enables a library to accept online payments from patrons using the Easy payments platform.
See https://tech.dibspayment.com/easy

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

# Plugin configuration
* Make sure that Koha's OPACBaseURL system preference is correctly set
* Enter the secret keys in the plugin configuration page

# API routes
The plugin requires that its API routes are added to Koha.
* Enable the plugin
* Restart the webserver after installing the plugin

# Testing
Testing information can be found at (https://tech.dibspayment.com/easy/test-information)
