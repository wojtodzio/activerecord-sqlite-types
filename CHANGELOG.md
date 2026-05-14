## [Unreleased]

## [0.3.1] - 2026-05-14

### Fixed

- Normalize `IpAddress` string serialization to match `IPAddr` serialization for Active Record lookup helpers

## [0.3.0] - 2026-05-14

### Added

- Add Rails migration generator for PostgreSQL-to-SQLite type preparation migrations
- Add migration helpers for reversible `inet`, `interval`, and PostgreSQL array conversions
- Add exact `text[]` rollback support and nested-array rollback validation for PostgreSQL migrations
- Add integration tests for ActiveRecord persistence, querying, migration data preservation, and generator output
- Preserve PostgreSQL array `NULL` elements across SQLite JSON-backed array types and migration rollbacks
- Preserve PostgreSQL array element order during JSON-to-array rollback conversions
- Add PostgreSQL rollback preflight validation for incompatible JSON array elements before schema changes
- Add PostgreSQL rollback preflight validation for the actual target array casts before schema changes
- Lock affected PostgreSQL array tables during rollback validation and restoration when a migration transaction is open
- Preserve SQL `NULL` array elements when restoring PostgreSQL `json`/`jsonb` arrays
- Reject invalid nested JSON array shapes without relying on PostgreSQL scalar array-length errors
- Serialize `:datetime` arrays in PostgreSQL-compatible timestamp JSON format for migrated-row equality queries
- Allow JSON-backed array subtypes to store broader JSON values after migration with best-effort subtype casting
- Reject JSON array numeric values that Rails would serialize as strings or `null`
- Match PostgreSQL `inet` casting for blank and invalid string assignments by casting them to `nil`

## [0.2.0] - 2025-10-24

### Fixed

- Fix Array namespace conflicts by using fully qualified `::Array` references in type definitions

## [0.1.0] - 2025-10-21

### Added

- Initial release
- `IpAddressType` for PostgreSQL `inet` type compatibility
- `ArrayType` for PostgreSQL array type compatibility with JSON storage
- `IntervalStringType` for PostgreSQL `interval` type compatibility
- Support for Rails 7.0+
