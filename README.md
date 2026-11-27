# rails_tia

Test Impact Analysis for Rails applications. Build a dependency map from RSpec or Minitest coverage, then select the test files affected by changed files.

> Under development (v0.1.0, unreleased). Interfaces may change.

## Requirements and installation

Ruby 3.3 or later is required. To collect coverage with the RSpec formatter, your test bundle must also include `rspec-core` (`~> 3.9`), which `rspec` and `rspec-rails` normally provide. For Minitest collection, the application supplies Minitest (verified with Minitest 5.27 on Rails 7.2 and Minitest 6.1 on Rails 8.1). Add rails_tia to your test dependencies once it is available:

```ruby
group :test do
  gem 'rails_tia'
end
```

Run `bundle install`. While the gem is unreleased, use a local checkout with `gem 'rails_tia', path: '/path/to/rails_tia'`.

## Workflow

1. Run the full suite on your default branch to generate a dependency map, on push or on a schedule.
2. Make that map available to change pipelines, using CI artifacts or your own transfer mechanism.
3. Select and run affected specs for each change.
4. Keep running full-suite checks and audit the predictions to detect missed failures.

Selection combines coverage dependencies, static mappings, and changed spec files themselves. Missing or stale maps trigger a full run. Configured paths, labels, commit message tokens, and large changes can also force a full run.

## Configuration

From your Rails application root, run:

```bash
bundle exec rails-tia init
```

This creates an editable `.rails_tia.yml`. If the project has a `test/` directory and no `spec/` directory, `init` generates the Minitest preset. Otherwise it generates the RSpec preset. Use `--runner minitest` or `--runner rspec` to choose explicitly, including before adding any tests.

Changes to dependencies, Rails configuration, database files, layouts, shared partials, shared spec setup, and CI definitions trigger a full run. Static mappings select existing specs by convention. For example, a change to `app/controllers/admin/users_controller.rb` selects `spec/requests/admin/users_spec.rb` if it exists, even for a new controller. Other settings inherit the runtime defaults, including Rails tracking and CI adapter detection.

Review the generated rules for your application's directory layout. Running `init` again keeps the existing file and exits with status 1. Without a configuration file, full-run paths, labels, tokens, and static mappings are empty. The following example shows additional settings you can customize.

The RSpec preset selects all system and feature specs for changes under `app/javascript/`, `app/assets/`, or `vendor/javascript/`, and for changes to the root `package.json` or npm, Yarn, pnpm, or Bun lockfile. If neither spec directory contains matching files, this rule contributes no specs. Coverage matches, other static mappings, changed specs, and full-run conditions still apply.

To use a different configuration file, set `RAILS_TIA_CONFIG` for map collection or pass `--config PATH` to the CLI. For example, `rails-tia init --config tia.yml` adds `tia.yml` to the generated full-run paths so editing the selection rules triggers a full run. Only configuration files inside the project root can match project changes.

```yaml
spec_glob: 'spec/**/*_spec.rb'
full_run_token: spec

map:
  fragment_dir: tmp/rails_tia/fragments
  path: tmp/rails_tia/map.json.gz
  max_age_days: 3

# Changes that coverage cannot reliably track should trigger a full run.
full_run:
  paths:
    - Gemfile.lock
    - config/**/*
    - db/**/*
    - spec/rails_helper.rb
    - spec/support/**/*
    - .gitlab-ci.yml
    - .github/workflows/**/*
  max_changed_files: 300
  labels:
    - 'pipeline:run-all-rspec'
  commit_message_tokens:
    - '[run-all-rspec]'

# Regex capture groups replace each %s in order. Only existing specs are selected.
static_mapping:
  - source: 'app/(models|jobs)/(.+)\.rb'
    test: 'spec/%s/%s_spec.rb'
  - source: 'app/controllers/(.+)_controller\.rb'
    test: 'spec/requests/%s_request_spec.rb'
  - source: 'app/views/([^/]+)/.+'
    test: 'spec/requests/%s_request_spec.rb'
  - source: 'app/(?:javascript|assets)/.+'
    test_glob:
      - 'spec/system/**/*_spec.rb'
      - 'spec/features/**/*_spec.rb'

described_class:
  enabled: true

rails:
  enabled: auto
  active_record: true
  action_view: true

ci:
  adapter: auto  # auto | gitlab | github_actions | git

metrics_path: tmp/rails_tia/metrics.json
```

Path globs use Ruby's `File.fnmatch?` with `FNM_PATHNAME | FNM_EXTGLOB`. Use `config/**/*` for nested paths; `config/**` does not match nested files. Static mapping sources are regular expressions, rather than path globs.

In a static mapping, `test` produces individual paths using the source's captures. Use `test_glob` for a fixed pattern or list of patterns relative to the project root. Absolute paths and `..` path components are invalid. Each matching source selects files found by those globs whose resolved paths are inside the project. This also applies when a file or directory is a symlink.

Rails support is enabled automatically when Rails is loaded. ActiveRecord tracking supplements coverage for model dependencies that coverage alone may miss.

ActionView tracking records rendered templates, partials, collections, and layouts
as dependencies of their consumer spec files. Shared partials and layouts are
recorded for every spec that renders them, including subsequent uses of compiled
templates. Set `rails.action_view: false` to disable this independently of
`rails.active_record`; `rails.enabled: false` disables both. Tracking initializes
after spec loading, so Rails can be required from `spec/rails_helper.rb`.

Only existing files inside the project root are recorded. For template files
symlinked within the project, both the symlink path and its resolved target
path are recorded, so changes to either select the consumer specs. Symlinks whose
targets are outside the project are skipped. Inline templates,
virtual identifiers, and files in external engines/gems are skipped. Renders in
context hooks belong to the consumer spec, and renders in suite hooks belong to
every recorded spec; renders during application/spec loading are discarded.
The integration suite verifies ERB rendering with Rails 7.2 (tested with 7.2.4).
Other Rails versions and HAML handlers have not been verified.

Collection cache hits still identify the collection's primary partial. However,
fragment/collection cache hits can skip nested partials and partial layouts, so
their notifications cannot identify every dependency. Generate maps with
fragment and collection caching disabled when relying on those nested dependencies,
or cover the affected paths with explicit `static_mapping` rules or
`full_run.paths` (for example, `app/views/**/*`). Keep full-suite audits enabled.
Static mappings remain necessary for new or unrendered templates and conditional
rendering paths absent from the map. After enabling tracking, regenerate existing
maps to collect the additional template edges.

RSpec described-class tracking is enabled by default, including without Rails. For each
executed example whose `described_class` is a named class or module, it adds the
definition files of that target and its ancestors (superclasses and included or
prepended modules) to the runnable consumer spec. This covers constant-only
targets whose definitions were loaded before the suite started, including targets
used through shared examples. Only files inside the project root are recorded;
descriptions without a class/module target, anonymous targets, built-in classes,
and unresolved or external definitions are skipped. Set `described_class.enabled: false` to disable
this supplementation independently of coverage and ActiveRecord tracking.

## Generate a map

Run from the project root, starting coverage before the application loads:

```bash
bundle exec ruby -rrails_tia/boot -S rspec \
  --require rails_tia/formatter --format RailsTia::Formatter
bundle exec rails-tia map merge
```

If your app loads `bootsnap/setup`, load `rails_tia/boot` first. It sets
`DISABLE_BOOTSNAP_COMPILE_CACHE=1`, which `bootsnap/setup` reads when it
initializes Bootsnap. If Bootsnap initializes earlier, move its setup after
`rails_tia/boot` so the setting takes effect.

If your app calls `Bootsnap.setup` directly, pass `compile_cache_iseq: false`
and `compile_cache_yaml: false` in the map collection process.
Bootsnap can still cache load path lookups during collection. Selection and
ordinary RSpec runs can use Bootsnap with their usual settings.

The formatter writes `map-<node>-<process>.json.gz` fragments under `map.fragment_dir`, using `CI_NODE_INDEX` and `TEST_ENV_NUMBER` when available. Collect fragments from all parallel workers before merging. Clear old fragments before each map generation so that previous runs cannot contaminate the map. Maps from failed tests or hooks are marked stale and cause selection to fall back to a full run.

Use `RAILS_TIA_FRAGMENT_PATH` to override the fragment output path. `map merge --fragments DIR --output PATH` overrides the merge input directory and output file.

### Minitest

Generate the Minitest preset from the application root:

```bash
bundle exec rails-tia init --runner minitest
```

The preset discovers `test/**/*_test.rb` and emits `test/` for a full run. Changes to shared test helpers and fixtures trigger the full suite. Model, controller and view changes select matching tests by convention, and frontend changes select the system tests under `test/system/`.

Generate the map from the full suite, including system tests under `test/`:

```bash
bundle exec ruby -rrails_tia/minitest bin/rails test test/ &&
  bundle exec rails-tia map merge
```

The opt-in entry point starts coverage before Rails loads and tracks tests run through Minitest autorun. It supports serial execution and Rails process workers. Thread-parallel map collection is unsupported because Ruby threads share coverage counters. Set `PARALLEL_WORKERS=1` for the map command if your Rails suite normally uses threads. Selected tests can run with the usual parallel settings.

Disable SimpleCov and any other tool that stops Ruby coverage while generating the map. Coverage must remain active through worker teardown and Minitest’s final hook. Tests using `ActiveSupport::Testing::Isolation` execute in another process and currently cause map generation to fail. In both cases the fragment remains stale.

Use the selection script below with `bundle exec ruby bin/rails test "${specs[@]}"` as its final command. Only map generation needs `-rrails_tia/minitest`. If you use `audit`, configure your JUnit reporter to include project-relative test file paths in the `file` attribute of failing test cases.

## Select and run specs

This Bash script runs selection from the project root, skips RSpec when no specs are selected, and fails the job if selection fails:

```bash
#!/usr/bin/env bash
bundle exec rails-tia select > specs.txt || exit "$?"
[ -s specs.txt ] || exit 0

specs=()
while IFS= read -r spec; do
  specs+=("$spec")
done < specs.txt
bundle exec rspec "${specs[@]}"
```

Selection prints one path per line to standard output and a metrics summary to standard error. Metrics are also written to `metrics_path`; use `select --metrics PATH` to override it. `select --junit-dir DIR` uses JUnit timings to estimate time savings.

When a full run is required, output contains only `full_run_token` (default: `spec`). Set this to a directory or another value RSpec accepts as a single argument. If a separate splitting script consumes a custom token, that script must translate it into a full run.

The Bash array preserves spaces, backslashes, and wildcard characters in output paths. Filenames containing newlines are unsupported.

### Local Git and explicit changes

The Git adapter compares `origin/master...HEAD` by default. Set `RAILS_TIA_DIFF_BASE` to use another base, such as `origin/main`. The base and common ancestor must be available locally; shallow clones may need more history. Supply a locally generated map when using this adapter.

To supply changed paths directly, use a newline-delimited file or standard input:

```bash
git diff --name-only HEAD~1 | bundle exec rails-tia select --changed-files-from -
```

This is useful for evaluating predictions against historical changes before enabling selective execution in CI.

## GitLab CI integration

### Authentication

The GitLab adapter targets GitLab 17+ API v4 and uses `PRIVATE-TOKEN` authentication for MR diffs, pipeline/job discovery, and artifact downloads. Set `RAILS_TIA_GITLAB_TOKEN` to a personal access token with `read_api`, or an equivalent project/group access token. Its owner needs access to the project's code, merge requests, and CI artifacts (typically Reporter or higher). A separate token is required even within the same project. Deploy tokens are unsupported.

Register the token as a masked CI/CD variable. If it is protected, ensure it is available to the MR pipelines that run selection. Missing tokens and API failures produce a nonzero exit status; they are not treated as an empty change list.

A normal `CI_JOB_TOKEN` does not cover all APIs needed by this adapter. See GitLab's [job token access documentation](https://docs.gitlab.com/ci/jobs/ci_job_token/#job-token-access), [access token scopes](https://docs.gitlab.com/user/profile/personal_access_tokens/#personal-access-token-scopes), and [MR diffs API](https://docs.gitlab.com/api/merge_requests/#list-merge-request-diffs).

### Map artifacts

Configure the source of the map artifacts:

```yaml
ci:
  adapter: gitlab
  gitlab:
    map_ref: main  # Default: master; set this to your default branch.
    map_pipeline_source: schedule
    map_job_name: rspec-map
    map_artifact_glob: tmp/rails_tia/fragments
```

Save the entire `map.fragment_dir` directory as an artifact from each map-generation job. In the selection job, fetch and merge the fragments before selecting specs:

```bash
bundle exec rails-tia map fetch || exit "$?"
bundle exec rails-tia select > specs.txt || exit "$?"
# Run the selected specs using the Bash script above.
```

`map_artifact_glob` accepts a project-relative directory, glob, or fragment file path. The adapter reads matching `.json` and `.json.gz` fragments from job artifact ZIPs. If you override `RAILS_TIA_FRAGMENT_PATH`, include that file in artifacts and adjust the matching path.

Supported job names are a single `map_job_name` or GitLab numeric parallel names such as `rspec-map 1/4`. All nodes must succeed and provide valid, fresh fragments from the same commit. Incomplete or invalid downloads fail and preserve the existing merged map. Other naming formats, including `parallel:matrix`, are unsupported. Ensure each job saves fragments from every process, and propagate RSpec and artifact-upload failures.

When no map fragments are available through the adapter's normal no-map path, `map fetch` removes the existing merged map so selection falls back to a full run. Artifact HTTP failures, including 404 responses, are errors. Redirects, such as GitLab.com artifact downloads served through a CDN, are followed; the token is sent only to the GitLab API origin. Use `map fetch --no-merge` to download without merging, or `--dest DIR` to change the download directory.

## GitHub Actions integration

Opt in to the GitHub Actions adapter in `.rails_tia.yml`. Set `map_workflow` to the workflow filename or its numeric ID. `map_event` defaults to `push`.

```yaml
ci:
  adapter: github_actions
  github_actions:
    map_workflow: rspec.yml
    map_event: push
    map_artifact_name: rails-tia-map
```

Save the example below as `.github/workflows/rspec.yml`. Add any services and setup steps your project needs before running RSpec.

```yaml
name: RSpec
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]

permissions:
  contents: read
  actions: read

jobs:
  rspec:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
          persist-credentials: false
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.4'
          bundler-cache: true

      - name: Generate map from the full suite
        if: github.event_name == 'push'
        run: |
          bundle exec ruby -rrails_tia/boot -S rspec \
            --require rails_tia/formatter --format RailsTia::Formatter
          bundle exec rails-tia map merge
      - uses: actions/upload-artifact@v4
        if: github.event_name == 'push'
        with:
          name: rails-tia-map
          path: tmp/rails_tia/map.json.gz
          if-no-files-found: error
          overwrite: true

      - name: Fetch the map
        if: github.event_name == 'pull_request'
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: bundle exec rails-tia map fetch
      - name: Run selected specs
        if: github.event_name == 'pull_request'
        shell: bash
        run: |
          bundle exec rails-tia select > specs.txt
          if [ -s specs.txt ]; then
            mapfile -t specs < specs.txt
            bundle exec rspec "${specs[@]}"
          fi
```

The default PR merge checkout needs both parents (`fetch-depth: 2`). If you check out the PR head explicitly, fetch the full history (`fetch-depth: 0`) so Git can find its common ancestor with the target commit. Selection uses labels from the PR event and the latest PR commit message for full-run rules. The example starts a new run when a label is added or removed. Other events use full runs.

The adapter looks for a successful run of the configured workflow on the PR target branch at the exact commit used as the baseline for the diff. Use `map_event: schedule` only when a scheduled run can cover that commit. GitHub runs scheduled workflows on the default branch tip, so PRs targeting other branches or commits without a matching scheduled run use the full suite.

Upload an artifact containing one merged `.json` or `.json.gz` map. If map generation is parallel, collect and merge the fragments from every worker before uploading. `map fetch` uses the same repository's `GITHUB_TOKEN` with `actions: read` permission. Downloads go in `map.fragment_dir/github-actions` by default, where `map merge` leaves them out when merging newly generated fragments. Use `--dest DIR` to override the download directory. [Artifact API permissions](https://docs.github.com/en/rest/actions/artifacts#list-workflow-run-artifacts)

Outside a PR, or when the matching run or map is unavailable or too old, `map fetch` clears the existing map and `select` runs the full suite. This includes a successful run without the named artifact and an artifact that expires or disappears between listing and download. A download `404` is treated as missing only if a fresh listing confirms the artifact is unavailable. Authentication failures, other API errors, and invalid maps cause `map fetch` to fail and preserve the existing map.

## Audit and diagnostics

```bash
bundle exec rails-tia audit --junit tmp/junit --predicted specs.txt
bundle exec rails-tia doctor
```

`audit` compares predictions with JUnit results from a full-suite run and exits with status 1 if a failing spec was omitted. Keep auditing full-suite runs after enabling selection to detect missed failures. `doctor` checks configuration, spec discovery, map freshness, the CI adapter, and static mappings.

Commands accept `--config PATH` and `--root PATH` to override the configuration file and project root.

## Continuous improvement reports

Set `RAILS_TIA_REPORT_DIR` in the map-generation, merge, selection and audit jobs to keep a history. Use a dedicated directory outside the map fragment directory. Relative paths resolve from the project root (including `--root`). Reporting is disabled when the variable is unset or empty.

Each invocation or RSpec worker writes one `<type>-<report_id>.json` file. Reports use schema version 1. They include a UUID, UTC timestamp, `rails_tia_version`, commit SHA and available GitHub Actions or GitLab job metadata. Set `CI_NODE_INDEX` from the matrix index on GitHub Actions to identify the shard. Fields without CI metadata are null.

If saving a history report or its archived map fails, rails_tia warns on standard error and continues. RSpec can finish writing its other formatter outputs, and the CLI returns the outcome of selection, merge or audit. Published history files use mode `0644` subject to the process umask.

| Type | What to compare across runs |
| --- | --- |
| `map_worker` | Spec and example counts, test failure status, number of Coverage reads (including the initial clear), cumulative seconds spent reading Coverage, scanning it and writing the fragment, fragment size, Ruby, test runner and Rails versions and active tracking features. `suite_seconds` covers formatter start through fragment write. Use CI job timings for end-to-end elapsed time across parallel workers. |
| `map_merge` | Source, spec, edge and fragment counts, ten sources with the most associated specs, times for merging, writing the map and archiving it, fragment IDs and merged map ID. Produced by both `map merge` and `map fetch` with merging enabled. |
| `select` | Changed files, selected specs, map ID, existing metrics and a stable full-run reason code. For selective runs, each changed file has counts of existing specs matched by the map and by static rules, plus whether the changed spec itself was selected. A spec can match more than one route. |
| `audit` | Failed and missed spec paths from the full run, validation errors, number of parsed JUnit files and the prediction ID when using a selection report. Invalid input gives `valid: false` and `missed_specs: null`. |

The merged map is also saved under `maps/<map_id>.json.gz` in the report directory. Map and fragment IDs are SHA-256 digests of the uncompressed map JSON. A worker's `fragment_id` links to the merge report, and a selection's `map_id` identifies the snapshot to use for replay. Compare reported phase times to locate expensive operations. To measure the overall cost of enabling Coverage, compare full runs on the same commit and worker configuration with and without mapping.

### Audit a saved selection

Use the selection report from the change being tested. For example, in Bash, starting with a fresh report directory for this job:

```bash
export RAILS_TIA_REPORT_DIR=tmp/rails_tia/reports
bundle exec rails-tia select --changed-files-from changed-files.txt > specs.txt || exit "$?"
selection=( "$RAILS_TIA_REPORT_DIR"/select-*.json )
[[ ${#selection[@]} == 1 && -f "${selection[0]}" ]] || exit 1
# Run the full suite and collect its JUnit XML, including results from failing jobs.
bundle exec rails-tia audit --selection-report "${selection[0]}" --junit tmp/junit \
  --expect-junit shard-1.xml --expect-junit shard-2.xml
```

Across jobs or workflows, pass the exact selection report for the commit under test. When both CI commit SHAs are available, audit requires them to match. The selection's `report_id` becomes the audit's `prediction_id`. The existing `--predicted specs.txt` mode also produces an audit report, with a null prediction ID.

Collect the full suite's XML in a fresh JUnit directory for each run. Audit reads every XML there. Supply one `--expect-junit` per expected file, relative to that directory. The report lists absent paths in `missing_junit_files`. The `junit_complete` field is true when all expected files were parsed as JUnit, false when any were missing or unreadable as JUnit, and null when no expectations were supplied. Check `valid` before counting misses. For example, all shards can arrive and still leave audit unable to identify the spec for a failed testcase.

### Store reports directly in S3

Set `RAILS_TIA_REPORT_DIR` at job level and use a fresh directory per job. After the producer steps, upload from every worker job and from the merge, selection and audit jobs, including when tests or audit fail. The following GitHub Actions step assumes the AWS CLI and AWS credentials are available and `RAILS_TIA_S3_URI` names a private bucket or prefix (for example, `s3://my-ci-history/rails-tia`). Configure credentials in the workflow, for example through [GitHub Actions OIDC](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws).

```yaml
- name: Store rails_tia history
  if: always()
  shell: bash
  run: |
    dir="${RAILS_TIA_REPORT_DIR:?}"
    base="${RAILS_TIA_S3_URI:?}/${GITHUB_REPOSITORY}"
    if [[ -d "$dir" ]]; then
      # Upload the snapshot before records that reference it.
      if [[ -d "$dir/maps" ]]; then
        aws s3 sync "$dir/maps/" "$base/maps/" --size-only --no-follow-symlinks
      fi
      aws s3 cp "$dir/" "$base/reports/$GITHUB_RUN_ID/$GITHUB_RUN_ATTEMPT/$GITHUB_JOB/" \
        --recursive --no-follow-symlinks --exclude '*' --include '*.json'
    fi
```

Retries of the upload use the same keys. Re-running rails_tia creates new report IDs, including on matrix jobs with the same job name. The same JSON files can be imported into an analytics database using `report_id` as the unique key. CI owns storage credentials and retention.

## Limitations

- Ruby coverage alone does not capture templates. ActionView tracking supplements rendered project files; use static mappings or full-run paths for unrendered/new templates, disabled tracking, and cache-hidden dependencies as described above.
- Files without executable method bodies may be missed when neither described-class nor ActiveRecord tracking identifies them. Use static mappings for those cases.
- Described-class tracking resolves the named constant's definition location, not every file that reopens the class. Ancestors and definition locations are cached on first use per target object during a map run; later changes to that object's ancestor chain are not tracked. It does not discover unexecuted dynamic dependencies or arbitrary classes referenced inside examples.
- Dependencies on external services and data files are not detected. Add relevant paths to `full_run.paths`.
- Changes to widely shared concerns or modules may still select most of the suite.

## Development documentation

- [Rails correctness fixture: execution, expected dependencies, and mutations](test_apps/rails_app/README.md)
- [Design decisions and architecture](docs/design.md)
- [Agent and contributor instructions](AGENTS.md)

## License

MIT
