# Configuration reference

Run `bundle exec rails-tia init` from your application root to generate `.rails_tia.yml`. It chooses Minitest when `test/` exists and `spec/` does not, and RSpec otherwise. Use `--runner rspec` or `--runner minitest` to choose explicitly.

For a custom file, pass `--config PATH` to CLI commands and set `RAILS_TIA_CONFIG` to the same file during collection. Relative paths in the YAML resolve from the project root even when the configuration lives in a subdirectory. The project root defaults to the working directory. Use `--root PATH` to override it for CLI commands.

The defaults below apply when a key is omitted, including when there is no configuration file. The generated presets populate `full_run.paths` and `static_mapping`, and the Minitest preset also sets `spec_glob` and `full_run_token`. Both presets add the generated configuration file to the full-run paths when it is inside the project. See the [RSpec preset](../lib/rails_tia/templates/rspec.yml) and [Minitest preset](../lib/rails_tia/templates/minitest.yml) for the rules.

Dots in the tables indicate nested YAML keys. For example, configure `map.max_age_days` as follows.

```yaml
map:
  max_age_days: 7
```

## Test discovery and output

| Key | Default | Purpose |
| --- | --- | --- |
| `spec_glob` | `spec/**/*_spec.rb` | Project-relative glob for discovering test files and selecting changed tests directly. The Minitest preset uses `test/**/*_test.rb`. |
| `full_run_token` | `spec` | Single line printed by `select` for a full run. Use a value your runner accepts as one argument, or handle it in your selection script. The Minitest preset uses `test/`. |
| `metrics_path` | `tmp/rails_tia/metrics.json` | Destination for JSON selection metrics. Override for one run with `select --metrics PATH`. |

## Dependency map

| Key | Default | Purpose |
| --- | --- | --- |
| `map.fragment_dir` | `tmp/rails_tia/fragments` | Directory where workers write fragments and `map merge` reads them. Start each collection with an empty directory. |
| `map.path` | `tmp/rails_tia/map.json.gz` | Merged map written by `map merge` or `map fetch` and read by `select`. |
| `map.max_age_days` | `3` | Maximum map age in days. A missing, empty, or stale map triggers a full run at selection. |

## Full-run rules

Any matching rule makes `select` print `full_run_token`.

| Key | Default | Trigger |
| --- | --- | --- |
| `full_run.paths` | `[]` | A changed path matches any listed glob. Use project-relative paths such as `Gemfile.lock` or `config/**/*` for files at any depth under `config/`. |
| `full_run.max_changed_files` | `300` | The number of changed files exceeds this limit. Set to `null` to disable the limit. |
| `full_run.labels` | `[]` | Any listed string exactly matches a merge or pull request label. |
| `full_run.commit_message_tokens` | `[]` | The commit message contains any listed string, for example `'[run all tests]'`. |

## Static mappings

`static_mapping` is a list of rules (default `[]`) for dependencies that coverage can miss, including new files. Each rule needs a `source` and at least one of `test` and `test_glob`. All three keys accept a string or a list of strings.

| Rule key | Meaning |
| --- | --- |
| `source` | A regular expression matching the entire project-relative changed path. A list combines its patterns as alternatives in one expression. Capture groups are numbered across the whole list. |
| `test` | A project-relative test path template. Each `%s` uses the next capture group in order. Use separate rules when different source patterns each supply a value for the same placeholder. |
| `test_glob` | A fixed project-relative glob. Matches must resolve to files inside the project. Absolute paths and `..` components are invalid. |

For example, append these rules to the generated `static_mapping` list to cover policy classes and browser code. If `app/policies/order_policy.rb` changes, the first rule selects `spec/authorization/order_spec.rb` when it exists. The second selects all existing system specs for a change under `frontend/`.

```yaml
- source: 'app/policies/(.+)_policy\.rb'
  test: 'spec/authorization/%s_spec.rb'
- source: 'frontend/.+'
  test_glob: 'spec/system/**/*_spec.rb'
```

## Dependency tracking

These settings apply during map collection.

| Key | Default | Purpose |
| --- | --- | --- |
| `rails.enabled` | `auto` | Enable Rails tracking when Rails is loaded. Set to `true` to enable available integrations explicitly or `false` to disable all Rails trackers. |
| `rails.active_record` | `true` | Track project model definitions identified by ActiveRecord query and instantiation events. |
| `rails.action_view` | `true` | Track project templates, partials, and layouts rendered through ActionView. |
| `rails.object_allocations` | `auto` | Track allocations on CRuby when Rails support is enabled. Set to `false` to disable the process-wide hook or `true` to require the native extension. |
| `rails.constant_reads` | `true` | Link literal qualified reads such as `Config::LIMIT` to project assignments using the existing line coverage. Applies when Rails tracking is enabled. |
| `rails.app_dirs` | `[]` | Additional project-relative directories for allocation and constant tracking alongside `app/` and `lib/`, for example `[components, engines/billing]`. |
| `described_class.enabled` | `true` | Track the definition files of an RSpec example's named `described_class` and its ancestors. Works independently of Rails. |

Regenerate the map to record allocation dependencies. Creating an ordinary Ruby object or Struct links its test file to the definitions of its named class and ancestors under the configured directories. This includes named ancestors of anonymous subclasses. Other collectors keep their own path rules.

Construction counts even if the test never uses the object. Shared mixins can have many consumers, and suite-hook allocations apply to every test. Background-thread allocations belong to the test or hook active at the time, so join asynchronous work before the test finishes. Reusing an instance created during boot or allocating other storage types such as Hash subclasses can leave dependencies unrecorded. Use static mappings for known consumers.

If the extension fails to load in auto mode on CRuby, map generation warns and marks the map stale for a full run. The legacy `rails.form_allocations` key is accepted with a deprecation warning when `rails.object_allocations` is omitted.

Constant tracking indexes Ruby files in the application directories and runnable test files matching `spec_glob` when map collection starts. A change to an indexed constant assignment can select a test that executed the referencing method, even when Rails preloaded the definition. A read outside a method uses file-level coverage. Regenerate the map after enabling tracking or changing the directories.

A method can execute without reaching every read in it. Relative names can also match assignments in multiple namespaces. Dynamic lookups such as `const_get`, unqualified names, aliases, inherited constants and values copied into another constant during boot can still need static mappings. Files added after collection starts or containing syntax Prism cannot parse are outside the index.

## CI adapters

`ci.adapter` accepts `auto` (default), `gitlab`, `github_actions`, or `git`. Automatic selection uses GitLab in GitLab CI and falls back to Git in a Git checkout. Choose `github_actions` explicitly to fetch workflow artifacts. The Git adapter reads a locally generated or copied map.

### GitLab

`map fetch` looks for the latest successful pipeline matching the configured ref and source. Set `RAILS_TIA_GITLAB_TOKEN` in CI as described in the [GitLab setup](../README.md#gitlab-ci).

| Key | Default | Purpose |
| --- | --- | --- |
| `ci.gitlab.map_ref` | `master` | Git ref that runs the map pipeline. Set to `main` for a pipeline on that branch. |
| `ci.gitlab.map_pipeline_source` | `schedule` | GitLab pipeline source used for map generation, for example `schedule` or `push`. |
| `ci.gitlab.map_job_name` | `null` | Job name required for fetching. For numeric parallel jobs such as `rspec-map 1/4`, use the base name `rspec-map`. |
| `ci.gitlab.map_artifact_glob` | `tmp/rails_tia/fragments` | Directory, glob, or file path inside each job artifact used to locate `.json` or `.json.gz` fragments. Match the paths actually archived by the job. |

### GitHub Actions

`map fetch` looks for a successful workflow run on the PR target branch at the diff's baseline commit. See the [GitHub Actions guide](github-actions.md) for workflow and artifact setup.

| Key | Default | Purpose |
| --- | --- | --- |
| `ci.github_actions.map_workflow` | `null` | Workflow filename (for example, `rspec.yml`) or numeric ID. Required for fetching. |
| `ci.github_actions.map_event` | `push` | Event that produces the map. Use `push` or `schedule`. |
| `ci.github_actions.map_artifact_name` | `rails-tia-map` | Exact name of the artifact containing the single merged `.json` or `.json.gz` map. |
