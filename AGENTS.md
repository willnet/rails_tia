# Contributor and agent guidelines

## Documentation

Write all repository documentation in English. Use English for commit messages and for pull request titles and descriptions.

- `README.md` covers installation, configuration, usage, CI integration, and limitations for users.
- `docs/design.md` explains the current design and the reasons behind it.
- `AGENTS.md` gives contributors and agents instructions for changing the repository.

Update the README when a change affects user-facing behavior or configuration. When a design decision changes, document the decision and its rationale in the design notes.

## Development and verification

Use Ruby 3.3 or later. Install dependencies with `bundle install` and run the specs with `bundle exec rake spec`. CI tests Ruby 3.3, 3.4, and 4.0. See the Gemfile for the Rails, ActiveRecord, and SQLite dependencies used in tests.

CI also runs the Minitest integration specs on Ruby 4.0 with Rails 8.1 and Minitest 6.1. Run the same specs locally from the repository root.

```sh
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rspec spec/integration/minitest_spec.rb
```

For code changes, review the specs for the affected behavior, run them, and run any necessary suite-wide checks. For documentation-only changes, check the text against the implementation and verify relative links, commands, and configuration examples.

## Design constraints

See the [design notes](docs/design.md) for the reasons behind these constraints.

- Start coverage before the application loads. Use cumulative line coverage and compare snapshots at RSpec file boundaries so SimpleCov can report the full run. Minitest clears counters at its existing test file boundaries.
- Account for context and suite hook attribution, excluding eager-load hits from the dependency map, and dependencies detected through ActiveRecord. When changing the formatter, check the load-order and hook specs.
- Distinguish a successful empty selection, a full-run fallback, and an error. Propagate errors when authentication or diff retrieval fails.
- For parallel maps, check that the fragments from all nodes and processes are present and consistent. Preserve the existing merged map if retrieval fails.
- Keep `select` output to one path per line or a single line containing the full-run token. Send diagnostics to standard error.
- Audit predictions against full-suite results. Failures in omitted specs are only observable when those specs run.

## Commit messages

Use the first line to summarize the change. In the body, explain why the change and the pull request were needed. Give readers the background and caveats they cannot infer from the diff. Include relevant issues, pull requests, bug reports, and design constraints.

Focus on the final change and its rationale. Omit the history of experiments and discarded ideas unless a reader is likely to ask about an alternative or a constraint will matter for a future decision. In those cases, explain the reason briefly.
