# Changelog

## 0.1.0

- Start `is_airlock`: `RecordedAirlock<R>`, an `Airlock<R>` whose record is an
  `is_journal` journal, and `witness`, which records an arrival exactly as
  it came, before anything reads it. Shaped to become `Witnessed` once
  `is_airlock_api` 0.3.0 adds one.
