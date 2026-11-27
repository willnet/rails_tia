---
name: rails-tia
description: Use rails_tia in a Rails application to select or run RSpec or Minitest tests affected by a change, set up dependency map collection in CI, or diagnose an unexpected test selection.
---

# Use rails_tia in a Rails application

Work from the application root. Check its test command, `.rails_tia.yml`, and existing CI jobs for the runner, map location, and full-run token. Find the installed gem directory with `bundle info rails_tia --path`. Its `README.md` contains runner commands and `docs/configuration.md` describes settings for that version.

## Select tests for a change

Run `bundle exec rails-tia select` with the input that matches the user's change.

- For a pull or merge request in configured CI, use the existing map fetch step before selection. The adapter supplies changed files and event metadata, including labels.
- For committed branch changes with the Git adapter, set `RAILS_TIA_DIFF_BASE` to the target ref (default `origin/master`). The comparison is `base...HEAD` and requires the merge base locally. Git reads a local map and cannot fetch one.
- For working-tree edits or a specified set of files, pass a newline-delimited list of project-relative paths to `bundle exec rails-tia select --changed-files-from FILE` (or `-` for stdin). For uncommitted work, include staged, unstaged, and relevant untracked files. Include deleted paths and both sides of renames. Explicit input bypasses the adapter, including label and commit-message overrides.

Keep stdout separate from stderr. Check the exit status before interpreting stdout. If selection or a required fetch fails, surface the error and stop. On success, interpret stdout as follows.

| Stdout | When asked to run tests |
| --- | --- |
| Empty | Skip the runner and report that no tests were selected. |
| A single configured `full_run_token` | Run the application's full suite. The RSpec preset emits `spec` and the Minitest preset emits `test/`. |
| Test paths | Pass each line as one argument to the runner, preserving spaces. Use `bundle exec rspec` or `bundle exec ruby bin/rails test` with those arguments. |

When asked which tests are affected, report the selection and any full-run reason from stderr.

## Set up map collection

For initial setup, add `rails_tia` to the test bundle, run `bundle install`, and generate a config with `bundle exec rails-tia init --runner rspec` or `--runner minitest`. Adapt existing configurations in place.

Collect from a full suite on the target branch, starting with an empty fragment directory. Load the collector before Rails and Bootsnap.

- RSpec: `bundle exec ruby -rrails_tia/boot -S rspec --require rails_tia/formatter --format RailsTia::Formatter`. If the project uses SimpleCov, start it with ordinary line coverage before loading `rails_tia/boot`.
- Minitest: `bundle exec ruby -rrails_tia/minitest bin/rails test test/`. Use one worker for thread-parallel suites. Disable SimpleCov during Minitest collection.

After all workers succeed, gather a distinct fragment from every node and process.

- **GitHub Actions.** Verify the complete set of fragments, run `bundle exec rails-tia map merge`, and publish the merged map. Set `ci.adapter` to `github_actions` and `ci.github_actions.map_workflow` to the producing workflow's filename or ID. Set `map_event` and `map_artifact_name` under `ci.github_actions` when they differ from `push` and `rails-tia-map`. The PR fetch step needs `GITHUB_TOKEN` with `actions: read`. Use checkout depth 2 for the PR merge commit or 0 for the PR head. The installed gem's `docs/github-actions.md` has a complete workflow.
- **GitLab.** Publish each job's fragments and configure the map ref, pipeline source, job name, and artifact path. Provide `RAILS_TIA_GITLAB_TOKEN` with `read_api` access in the MR job.
- **Local Git.** Merge the fragments and keep the map at `map.path`.

With the GitHub Actions or GitLab adapter, run `bundle exec rails-tia map fetch` before selection in the PR or MR job.

## Explain a selection

Use the selection summary on stderr and `bundle exec rails-tia doctor` to check discovery, configuration, map freshness, and the adapter. A missing or stale map requests a full run. On GitHub Actions, check that a successful map workflow produced an artifact for the exact commit used as the PR diff baseline. For a surprising subset, check the recorded dependencies, matching `static_mapping` rules, and changed test files. Use naming rules for new files with predictable tests and `full_run.paths` for changes with suite-wide effects.

To investigate missed failures, save the selection and compare it with JUnit XML from a **full suite on the same commit**. Run `bundle exec rails-tia audit --predicted specs.txt --junit DIR`. Gather XML from every shard, including failures, into a fresh directory. Use a repeated `--expect-junit FILE` for known shard outputs. A failing testcase needs a project-relative `file` attribute.
