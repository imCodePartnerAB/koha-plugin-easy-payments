# Changelog

All notable changes to this project will be documented in this file.

## [00.00.08-1] - 2026-02-24

### Added
- **Koha::Logger support** - Added structured logging with `Koha::Logger` when available, falling back to `warn` otherwise. Provides better integration with Koha's logging infrastructure.
- **Configurable HTTP timeout** - Added `_ua()` helper method with 20-second default timeout to reduce timeout errors on slow networks.
- **Configurable API selftest** - Added `enable_api_selftest` configuration option to enable/disable the API connectivity test on payment page load. Disabled by default to avoid unnecessary delays.

### Changed
- Replaced all `warn` statements with structured `_log()` calls using appropriate log levels (`error`, `warn`, `info`).
- All `LWP::UserAgent` instances now use consistent timeout configuration.

## [00.00.08] - 2024-03-28

- Previous release
