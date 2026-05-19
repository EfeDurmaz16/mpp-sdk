# Ruby MPP SDK

This package is a small, dependency-free Ruby surface for MPP protocol helpers.

The initial implementation is intentionally model-first:

- charge intent request validation
- server-side friendly wire serialization
- focused Minitest coverage

Session, subscription, and Solana verification helpers should land as separate
small commits so each protocol surface remains easy to review.

## Running Tests

```bash
cd ruby
ruby -Ilib:test test/run.rb
```
