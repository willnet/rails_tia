# rails_tia

rails_tia uses coverage from a full RSpec or Minitest run on your default branch to map Rails project files to tests. For each pull or merge request, it selects tests that match the map or a naming rule, plus any changed test files.

> rails_tia is under active development. Its command-line interface and configuration options may change between releases.

## Installation

Use Ruby 3.3 or later with Minitest or `rspec-core` (`~> 3.9`). Add rails_tia to your application's Gemfile.

```ruby
gem 'rails_tia', group: :test
```

Bundler installs Rubydex for constant tracking even when the collector is disabled. If a precompiled Rubydex gem is unavailable, its source build also requires a Rust toolchain. See the [Rubydex platform packages](https://rubygems.org/gems/rubydex/versions/0.4.4).

Installing the source gem requires make and, on CRuby, a C compiler. For a local path dependency, run `bundle install` and `bundle exec rake compile` in the gem checkout using the Ruby that generates the map.

Run these commands from the application root to install dependencies and generate `.rails_tia.yml`.

```bash
bundle install
bundle exec rails-tia init
```

`init` chooses Minitest when `test/` exists and `spec/` does not. Otherwise it chooses RSpec. Use `--runner minitest` or `--runner rspec` to choose explicitly.

### AI agent skill

The gem includes a [rails-tia skill](skills/rails-tia/SKILL.md) for selecting tests, configuring map collection, and explaining selection results. From the application root, copy the skill into the project directory for your agent. Repeat the copy after upgrading the gem to pick up skill updates.

**Codex**

```bash
mkdir -p .agents/skills
cp -R "$(bundle info rails_tia --path)/skills/rails-tia" .agents/skills/
```

For example, ask “Use rails-tia to run the tests affected by my uncommitted changes.”

**Claude Code**

```bash
mkdir -p .claude/skills
cp -R "$(bundle info rails_tia --path)/skills/rails-tia" .claude/skills/
```

In Claude Code, enter `/rails-tia Run the tests affected by my uncommitted changes` to invoke the skill directly.

## Configuration

Review the generated `.rails_tia.yml` for your application's layout. Use `full_run.paths` for changes that affect the whole suite and `static_mapping` for files you can match to tests by name. The [configuration reference](docs/configuration.md) covers every setting, its default, and the rules generated for each runner.

## Generate a map

From the project root, run the full suite with an empty fragment directory (`tmp/rails_tia/fragments` by default). Load the collector before Rails and `bootsnap/setup` so it can start coverage and disable Bootsnap's compile cache. If you call `Bootsnap.setup` directly, pass `compile_cache_iseq: false` and `compile_cache_yaml: false` during collection.

### RSpec

```bash
bundle exec ruby -rrails_tia/boot -S rspec \
  --require rails_tia/formatter --format RailsTia::Formatter
```

To generate a SimpleCov report in the same run, put `require 'simplecov'` and `SimpleCov.start` in `spec/coverage_setup.rb` and pass `-r./spec/coverage_setup` before `-rrails_tia/boot`. If `rails_helper.rb` starts SimpleCov, move that setup into the shared file and use `require_relative 'coverage_setup'` in the helper. Keep ordinary line coverage enabled, with optional branch coverage. One-shot line coverage is unsupported.

### Minitest

With the Minitest preset, pass `test/` to include system tests.

```bash
bundle exec ruby -rrails_tia/minitest bin/rails test test/
```

Map collection supports serial execution and Rails process workers. For thread-parallel suites, set `PARALLEL_WORKERS=1` during collection. Disable SimpleCov and any other tool that stops coverage before Minitest finishes. Tests using `ActiveSupport::Testing::Isolation` cause collection to fail.

### Merge the fragments

After a successful run, gather the fragments from every node and process in `map.fragment_dir` and merge them into `tmp/rails_tia/map.json.gz` (the default `map.path`).

```bash
bundle exec rails-tia map merge
```

Fragment names use `CI_NODE_INDEX` and `TEST_ENV_NUMBER` when set. To customize paths, set `RAILS_TIA_FRAGMENT_PATH` per worker or pass `--fragments DIR` and `--output PATH` to `map merge`. A failed test or hook marks the map stale and triggers a full run at selection.

## Select and run tests

`select` prints one path per line or nothing when no tests match. A missing or stale map, or a matching full-run rule, produces a single `full_run_token` (`spec` for RSpec, `test/` for the Minitest preset). This Bash script preserves paths with spaces, skips an empty selection, and propagates errors.

```bash
#!/usr/bin/env bash
set -e
bundle exec rails-tia select > specs.txt
[ -s specs.txt ] || exit 0

specs=()
while IFS= read -r spec; do
  specs+=("$spec")
done < specs.txt
bundle exec rspec "${specs[@]}"
```

For Minitest, use `bundle exec ruby bin/rails test "${specs[@]}"` on the last line. If you customize `full_run_token`, use a value your runner accepts as one argument, or handle it in your script. Paths containing newlines are unsupported.

`select` sends its summary to standard error and writes metrics to `tmp/rails_tia/metrics.json` by default. Use `--metrics PATH` to change the output file or `--junit-dir DIR` to estimate time savings from JUnit timings.

### Local Git and explicit changes

Outside GitLab, automatic adapter selection uses Git. The Git adapter cannot fetch maps, so generate one locally or copy a merged map to `map.path`. It compares `origin/master...HEAD` by default. Set `RAILS_TIA_DIFF_BASE` to use another base, such as `origin/main`. Fetch enough history to include the common ancestor.

To supply project-relative paths yourself, pass a newline-delimited file or use `-` for standard input.

```bash
bundle exec rails-tia select --changed-files-from changed-files.txt
```

## CI integration

When using CI event data, the GitLab and GitHub Actions adapters select individual tests only for `merge_request_event` and `pull_request`, respectively. Other events trigger a full run.

### GitLab CI

Store a personal, project, or group access token in the masked CI/CD variable `RAILS_TIA_GITLAB_TOKEN`. Make it available to merge request jobs. The adapter targets GitLab 17+ and requires `read_api` access to merge requests, pipelines, and job artifacts.

Configure the map pipeline in `.rails_tia.yml`.

```yaml
ci:
  adapter: gitlab
  gitlab:
    map_ref: main  # Defaults to master.
    map_pipeline_source: schedule
    map_job_name: rspec-map
    map_artifact_glob: tmp/rails_tia/fragments
```

In the map job, run the full suite with coverage and publish the fragment directory from every worker. Use a single job or GitLab's numeric parallel jobs (e.g. `rspec-map 1/4`). If you customize fragment paths, update both the job artifacts and `map_artifact_glob`.

In merge request jobs, run `bundle exec rails-tia map fetch` before selection. It merges fragments from the latest successful matching pipeline. If no pipeline matches, selection runs the full suite. Incomplete jobs, invalid or stale fragments, and API or download errors fail the fetch and preserve the existing map. Stop the job if fetching fails.

### GitHub Actions

Set `ci.adapter` to `github_actions` so pull request jobs can fetch the map published by your full-suite workflow. The [GitHub Actions guide](docs/github-actions.md) includes a complete RSpec workflow and a matrix example for parallel collection.

## Audit and diagnostics

Periodically run the full suite on the same commit as a selection. Compare its JUnit results with the saved prediction to find failures the selection missed.

```bash
bundle exec rails-tia audit --predicted specs.txt --junit tmp/junit
```

Collect XML from every shard, including failed jobs, in a fresh directory. Each failing testcase needs a project-relative `file` attribute. Pass `--expect-junit FILE` once per expected XML file, relative to that directory, to detect missing shards. Audit exits with status 1 for a missed failure or invalid input.

Run `bundle exec rails-tia doctor` to check configuration, test discovery, map freshness, the CI adapter, and static mappings.

### Run history

Set `RAILS_TIA_REPORT_DIR` (for example, `tmp/rails_tia/reports`) to record map generation timings, merge statistics, selection reasons, and audit results as JSON. Use a fresh directory per job outside `map.fragment_dir` and save it as a CI artifact or upload it to private storage, even when tests fail. The merge also saves the map under `maps/<map_id>.json.gz`.

To link an audit to its prediction, replace `--predicted specs.txt` with `--selection-report PATH`, using the `select-<report_id>.json` file from the commit under test.

## Tracking and limitations

- **Ruby and ActiveRecord.** Line coverage records code exercised by the suite. Rails tracking adds model definitions observed through ActiveRecord. On CRuby, creating an object of a preloaded application class can also link the test to its definition, for example when a request instantiates a form with declarative validations. See the [allocation tracking settings](docs/configuration.md#dependency-tracking). Reads such as `Config::LIMIT` can link a test that executes the referencing method to the file defining the constant. RSpec also tracks definition files for each named `described_class` and its ancestors, even when an example executes no lines in those files. Reopened classes and unexecuted code can still need static rules.
- **Views.** ActionView records rendered templates, partials, and layouts inside the project. Fragment and collection caching can hide nested renders. Disable caching during collection or cover those views with static mappings or full-run paths. New and unrendered templates also need rules.
- **External dependencies.** Coverage cannot see dependencies on services or data files. Add project files that affect them to `full_run.paths`.

Rails tracking starts automatically when Rails is loaded. Disable individual trackers with `rails.active_record: false`, `rails.action_view: false`, or `described_class.enabled: false`.

## Development

- [Design decisions and architecture](docs/design.md)
- [Rails test fixture](test_apps/rails_app/README.md)
- [Contributor guidelines](AGENTS.md)

## License

[MIT](LICENSE.txt)
