# Design decisions

These notes explain why rails_tia works the way it does and which behaviors future changes need to preserve. See the [README](../README.md) for usage and configuration and the [contributor guidelines](../AGENTS.md) for instructions on changing the repository.

## Purpose and components

Rails applications are the project's focus. The RSpec and Minitest entry points use the application's test runner. Keeping both runners out of the gem's runtime dependencies lets users install the CLI independently.

A full test run on the default branch builds a dependency map at test file granularity. Each change pipeline uses that map to select the spec files affected by its changed files.

- `boot.rb` starts coverage before the application loads. `formatter.rb` writes spec and hook dependencies to map fragments.
- `rails_support.rb` supplements coverage with dependencies observed through Rails and ActiveRecord.
- `action_view_support.rb` records template dependencies from ActionView rendering notifications.
- `described_class_support.rb` records the files that define an executed example's described class and its ancestors.
- `map.rb` saves, loads, and merges maps and checks their freshness.
- `predictor.rb`, `static_mapping.rb`, and `fallback.rb` handle reverse dependency lookup, static mappings, and full-run decisions.
- The adapters in `ci/` retrieve change information and map fragments. The CLI connects these operations and handles input and output.
- `audit.rb`, `junit_report.rb`, and `metrics.rb` validate predictions and measure how much test execution a selection can save.

## Coverage collection and granularity

Call `Coverage.start(lines: true)` before loading the application. At spec file boundaries, read coverage with `Coverage.result(stop: false, clear: true)`. Clearing the counters after each read lets the formatter identify files executed in that interval without comparing cumulative snapshots.

With `oneshot_lines`, clearing the results does not make Ruby record a previously executed line again. The map would attribute that line only to the first spec that ran it.

On Ruby 3.4.12 with Bootsnap 1.21.1, loading `bootsnap/setup` after starting coverage causes initialization of the instruction sequence compile cache to fail. In Savanna's model, request, and system specs, disabling only the compile cache produced the same map as disabling Bootsnap entirely. The coverage entry point, `rails_tia/boot`, sets `DISABLE_BOOTSNAP_COMPILE_CACHE` so the load path cache remains available.

Reading coverage for every example would substantially increase the number of reads. An earlier README recorded a Rails run with 1,966 spec files. Collecting coverage per spec file took 25–31 ms per read and about 53 seconds in total. Those timings describe that particular environment.

## Hook attribution and startup dependencies

Group start and finish notifications let the formatter attribute `before/after(:context)` hooks, including their `:all` aliases, to the spec that runs the group. Dependencies from `before/after(:suite)` apply to every spec. If a test or hook fails, the formatter saves the map with a stale timestamp so prediction falls back to a full run.

The formatter clears coverage once at suite start. Keeping the class definition lines executed during Rails eager loading would make every spec appear to depend on every file.

## Minitest attribution and Rails process workers

The Minitest adapter switches files before each test method, so setup, teardown, ActiveRecord queries and rendered templates belong to the runnable test. During test loading a class trace records the test files that open each runnable class. A shared test can be included by any of those files. The collector attributes dependencies to all of them and links the files to each other so a selective run loads the same class. For generated classes it can also resolve the method or constant definition. The collector clears coverage at file or suite boundaries. The adapter loads before the application and registers an early `after_run` hook so later application hooks finish before the fragment is published.

Rails runs tests in forked workers but sends reporter notifications to the parent. Each worker collects locally and writes its map to a directory unique to that run after worker cleanup. The parent checks the actual pool size, including idle workers, before combining the worker maps into one CI fragment. A worker that encounters a collection error continues draining the Rails queue and returns from cleanup so Rails can deregister it. Its missing or invalid map fails collection in the parent. A stale placeholder protects against interrupted runs and coverage stopped by another tool before the final flush. Rails isolation forks again inside a test, beyond the worker collector, so an isolated test invalidates collection. Thread-parallel tests cannot be separated by clearing process-wide counters.

## ActiveRecord dependencies

A model can be used after loading without executing another line of its definition. Coverage alone can miss uses of a model such as this one:

```ruby
class Account < ApplicationRecord
  belongs_to :user
end
```

The collector subscribes to `sql.active_record` and `instantiation.active_record`. It resolves each model name to its definition file with `Module.const_source_location` and adds that dependency. In one Rails application measured in an earlier README, this increased the edge count from 402 to 594, about 48%. Rails tracking is enabled by default so an omitted setting does not silently drop model dependencies.

## ActionView dependencies

Issue #27 describes shared partials and layouts whose consumers are difficult to infer from filenames. The collector takes the `identifier` from an ActionView rendering notification and adds the template to the existing map for each spec that renders it. This uses the existing map format, predictor, and coverage granularity. The `rails.action_view` setting defaults to enabled and can be disabled independently of ActiveRecord tracking. Disabling Rails support turns off both subscriptions.

Rendering tests on Rails 7.2.4 confirmed the `render_template.action_view`, `render_partial.action_view`, `render_collection.action_view`, and `render_layout.action_view` notifications. Layouts specific to partials do not emit `render_layout`, so the collector also subscribes to `!render_template.action_view`, which fires when each template renders. Observing rendering lets later specs acquire dependencies even after compilation. The `layout` payload is a virtual name. The collector uses the absolute `identifier` to find the file, verifies that the file exists and resolves inside the project, and stores a root-relative path in a set. HAML and other Rails versions remain unverified.

When a template is rendered through an in-project symlink, the collector records both the identifier relative to the project root and the resolved target relative to the real root. A change to either the link or the target can affect its consumers. The set deduplicates the paths when they coincide. A symlink that points outside the project contributes neither path.

The formatter subscribes in `start`, after spec loading, discards dependencies accumulated during boot, and flushes notifications at the same boundaries as coverage. Context hooks and shared examples contribute to the consuming spec. Suite hooks contribute to every spec. The formatter retains the ActiveRecord and ActionView subscription tokens to prevent duplicate subscriptions. An `ensure` in `stop` unsubscribes even when saving the map fails.

On Rails 7.2.4, a collection cache hit still reports its primary partial's identifier. A fragment or collection cache hit can skip rendering a nested partial or its layout, so no rendering notification identifies those files. The rendering tests cover this limit. The collector does not copy dependencies from another spec that populated the cache. Applications that rely on nested dependencies can disable rendering caches during map generation, add static rules, or configure full-run paths. Static mappings still cover new or unrendered templates. Continue auditing selection against full-suite runs.

## Dependencies from `described_class`

Issue #26 describes classes that contain only constants or declarations. Once the suite clears coverage, using such a class can leave no coverage hits. Plain Ruby classes and models used without SQL may also produce no ActiveRecord notifications. For each executed example, the collector reads the group's `described_class` and adds definition files for the named class or module and its `ancestors`. This works independently of Rails and is enabled by default. Set `described_class.enabled: false` to disable it.

At example start, the formatter completes the usual spec switch and coverage flush before calling `Map#add` for the runnable top-level group's spec. Shared examples contribute to the consuming spec, and contributions from multiple groups in one spec file form a union. The existing coverage reads, spec file granularity, and map format also serve this collector. Coverage tests continue to verify context hook attribution.

The collector resolves each part of the constant name without searching inherited constants. It stops if it encounters a registered autoload and checks that the final constant is the original object before looking up its definition with `const_source_location`. It records relative paths only for real files inside the project. Strings, anonymous objects, built-ins, removed constants, and external definitions contribute no paths.

Each formatter caches results by class object identity for its own lifetime. Repeated examples can reuse the ancestor list and definition lookups for a target, and different targets can reuse lookups for common ancestors. Redefining a class under the same name gives it a different object identity and a separate cache entry.

The cache reflects the ancestors and definition locations at first use. It can miss ancestors added later to the same object, definitions spread across files that reopen a class, and dynamic dependencies on paths that never execute. Continue using static mappings, ActiveRecord tracking, and full-suite audits alongside this collector.

## Spec selection and full-run fallback

The predictor takes the union of the map's reverse lookup, static mappings, and changed spec files themselves. It filters out spec paths that disappeared after a deletion or rename so RSpec receives existing paths.

A missing or stale map, a pipeline outside a merge request, a large change, or an explicit full-run request triggers the full suite. The consuming project configures full-run paths for changes such as gem dependencies, CI definitions, migrations, and external data. Static mappings can cover templates and new files.

`init` writes these project-level rules as an editable Rails preset. It includes conventional paths even when they do not yet exist, so adding the first migration or request spec later needs no setup change. The project directories select the initial runner preset. When both suites exist, RSpec remains the default for compatibility and `--runner` lets the user choose which suite the configuration describes. Keeping the preset in the generated file lets existing projects retain their selection policy across gem upgrades.

Selection matches changed files by their project-relative paths. When generating a full-run rule for the configuration itself, `init` resolves the project root and the configuration's parent directory so that a directory symlink produces the same rule as the tracked path. Glob mappings likewise check the resolved location of each spec, since an in-project symlink can point into a different checkout.

Ruby coverage cannot associate a JavaScript module or stylesheet with the browser scenarios that exercise it. The preset therefore maps frontend changes to the conventional browser suites for the chosen runner (`spec/system/` and `spec/features/` for RSpec, `test/system/` for Minitest). A separate `test_glob` field keeps source captures in existing `test` templates literal, including filenames that contain glob metacharacters. Glob results are shared across changed paths within one prediction and refreshed for the next prediction.

A successful prediction can select zero specs. Authentication failures and errors retrieving diffs or artifacts must propagate as errors. Treating them as an empty change list could let a job succeed while skipping required tests.

## Parallel maps and artifact integrity

Each process saves its own fragment. The GitLab adapter enumerates fragments in the artifact ZIP so it can handle the filenames and process counts used by the job. For numeric parallel jobs, it checks that all nodes succeeded, their indices are consecutive, and their fragments are present, valid, fresh, and from the same commit. A retrieval error preserves the existing merged map. When retrieval succeeds and no map is available, the adapter workflow removes the old map so selection falls back to the full suite.

For a GitHub Actions PR merge checkout, the first parent of the merge commit is the baseline for both the diff and the map. A direct PR head checkout uses its common ancestor with the target commit from the event. The target branch can advance while CI is running, so the adapter looks for a successful workflow run at that exact baseline commit.

The workflow that generates the map collects fragments from all workers and uploads one merged map. The fetching job validates that map and saves it in a subdirectory so a later `map merge` in the same workspace cannot mix it with newly generated fragments.

A missing successful run, a missing artifact, or a confirmed expiry triggers a full run. A download `404` can also indicate insufficient access, so the adapter lists artifacts again and falls back to the full suite only when that listing confirms the artifact is missing or expired.

The GitHub Actions adapter requires explicit configuration. Existing GitHub Actions workflows that use the generic Git adapter through `auto` can keep their checkout and diff settings.

GitLab and GitHub Actions can redirect artifact downloads to signed URLs. The HTTP client follows redirects and strips authentication headers when the origin changes, preventing the API token from reaching the signed URL's host. Error messages show only the original request URL to keep signed URLs out of CI logs.

## Ongoing validation

Selective runs cannot reveal failures in specs they omit. Use `audit` to compare predictions with JUnit results from full-suite runs on an ongoing basis. Before enabling selective execution, offline checks using historical lists of changed files can help estimate savings and evaluate missed failures.

## Regression tests with a Rails application

`test_apps/rails_app` is a small Rails application with dependency sets that can be checked by hand. Keeping it under `test_apps` rather than `spec/fixtures` keeps its specs out of default spec discovery. It shares the repository's root bundle and is excluded from the distributed gem.

To compare collectors, the fixture keeps separate handwritten expectations for the collected map and for the predictor's selected specs. Exact dependency sets for dedicated source files catch both missing consumers and unrelated specs added by mistake. For suite hooks, the expected set of all specs comes from the fixture's file list, independently of the map. Template selection also runs against a map with runtime dependencies removed to isolate the contribution of static rules.

The fixture loads its model before the suite starts. Comparing normal loading, eager loading, and runs with ActiveRecord tracking disabled shows which dependencies come from executing the model definition on first load and which come from the ActiveRecord collector. Shared data setup avoids SQL carrying a model name so setup alone cannot give every spec a model dependency.

Each child process runs a temporary copy with its own database, map fragments, and environment. Normal and eager-loading runs exercise definition order and fixed seeds. Each run checks several cases to limit startup costs. Mutation tests retain the map from the passing baseline, then check structured assertion failures in both the full and selected runs after the change. This ensures that a startup exception cannot count as detecting the injected fault. The fixture measures correctness. Performance needs to be evaluated separately.

## CI run history

When a job sets `RAILS_TIA_REPORT_DIR`, the formatter and CLI write a JSON report for each operation. The consuming CI workflow authenticates to its storage provider and transfers the files, so the gem needs no cloud SDK or CI artifact service. Each report has a UUID and is published by renaming a temporary file. Parallel jobs can upload to the same destination without filename collisions, and retrying an upload reuses the same key.

The SHA-256 digest of the uncompressed map JSON identifies the map used for prediction. Maps from the same commit can differ in their dependencies or generation time. Hashing the JSON also works with existing maps and preserves their IDs across recompression. A merge archives the map under its ID and records the IDs of its fragments so a prediction can be traced back to the workers' timings and tracking settings. Timings use a monotonic clock and follow the existing coverage read and clear boundaries.

Passing the selection report to `audit` carries the prediction's UUID into the audit record. Two predictions can select the same specs from different changed files or maps and still be evaluated separately. A plain list of predicted paths carries no prediction ID.

For parallel suites, the caller can supply the expected XML paths relative to the JUnit directory. Audit records whether every expected file could be parsed as JUnit and whether the inputs identify the spec for every failure. All shards can arrive even when a failing testcase has no file path. Without an expected file list, completeness is unknown. Invalid audit inputs produce a null list of missed specs so they can be excluded from missed-failure counts.

If saving optional history fails, rails_tia warns on standard error so other RSpec formatters can finish writing JUnit and each command can return its primary result. Failure to save the working map or read a prediction supplied as audit input still fails the operation.
