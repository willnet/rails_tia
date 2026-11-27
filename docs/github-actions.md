# GitHub Actions

Run the full suite on pushes to the target branch and publish its dependency map. Pull requests fetch the map for their exact diff baseline and use it to select tests. Enable the adapter in the application's `.rails_tia.yml`.

```yaml
ci:
  adapter: github_actions
  github_actions:
    map_workflow: rspec.yml
    map_event: push
    map_artifact_name: rails-tia-map
```

## RSpec workflow

Save this as `.github/workflows/rspec.yml`. Replace `main` with your target branch. The example uses the application's `.ruby-version`, the default map paths, and the RSpec preset. Include any database or service setup your suite requires.

```yaml
name: RSpec

on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]

permissions:
  contents: read

jobs:
  map:
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Generate and merge the map
        run: |
          bundle exec ruby -rrails_tia/boot -S rspec \
            --require rails_tia/formatter --format RailsTia::Formatter
          bundle exec rails-tia map merge
      - uses: actions/upload-artifact@v4
        with:
          name: rails-tia-map
          path: tmp/rails_tia/map.json.gz
          if-no-files-found: error
          overwrite: true

  selected:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: read
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
          persist-credentials: false
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Fetch the map
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: bundle exec rails-tia map fetch
      - name: Run selected specs
        shell: bash
        run: |
          bundle exec rails-tia select > specs.txt
          mapfile -t specs < specs.txt
          if (( ${#specs[@]} )); then
            bundle exec rspec "${specs[@]}"
          fi
```

The default PR checkout needs `fetch-depth: 2` to read the merge commit's parents. For an explicit PR head checkout, use `fetch-depth: 0` so Git can find the merge base. The `labeled` and `unlabeled` events refresh selection when a full-run label changes. For a Minitest application, use the [Minitest collection command](../README.md#minitest) and run the selected paths with `bundle exec ruby bin/rails test "${specs[@]}"`.

If no successful workflow run matches the baseline, or the map is missing, expired, or stale, selection requests the full suite. Authentication errors, other API errors, and invalid maps fail the fetch step. If you generate maps on a schedule, set `map_event: schedule`. Pull requests still need a map for their exact baseline to use selective execution.

## Collect a map across a matrix

Replace the `map` job with the two jobs below under `jobs`. This example splits `spec/**/*_spec.rb` across two workers, with one RSpec process on each worker. Use your existing splitter if your suite uses a different file pattern. Give each job's fragment file and intermediate artifact a distinct name so all fragments reach the merge job. [GitHub artifact transfer example](https://github.com/actions/download-artifact/blob/v4/README.md#download-multiple-filtered-artifacts-to-the-same-directory)

```yaml
map-shard:
  if: github.event_name == 'push'
  runs-on: ubuntu-latest
  strategy:
    matrix:
      shard: [0, 1]
  steps:
    - uses: actions/checkout@v4
    - uses: ruby/setup-ruby@v1
      with:
        bundler-cache: true
    - name: Run this shard with coverage
      shell: bash
      env:
        CI_NODE_INDEX: ${{ matrix.shard }}
        SHARD_COUNT: ${{ strategy.job-total }}
      run: |
        shopt -s globstar nullglob
        files=(spec/**/*_spec.rb)
        specs=()
        for ((i = CI_NODE_INDEX; i < ${#files[@]}; i += SHARD_COUNT)); do
          specs+=("${files[i]}")
        done
        (( ${#specs[@]} )) || { echo "No spec files for shard $CI_NODE_INDEX" >&2; exit 1; }
        bundle exec ruby -rrails_tia/boot -S rspec \
          --require rails_tia/formatter --format RailsTia::Formatter "${specs[@]}"
    - uses: actions/upload-artifact@v4
      with:
        name: rails-tia-fragments-${{ matrix.shard }}
        path: tmp/rails_tia/fragments/map-${{ matrix.shard }}.json.gz
        if-no-files-found: error
        overwrite: true

map-merge:
  needs: map-shard
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: ruby/setup-ruby@v1
      with:
        bundler-cache: true
    - uses: actions/download-artifact@v4
      with:
        pattern: rails-tia-fragments-*
        path: tmp/rails_tia/fragments
        merge-multiple: true
    - name: Merge both shards
      run: |
        test -s tmp/rails_tia/fragments/map-0.json.gz
        test -s tmp/rails_tia/fragments/map-1.json.gz
        bundle exec rails-tia map merge
    - uses: actions/upload-artifact@v4
      with:
        name: rails-tia-map
        path: tmp/rails_tia/map.json.gz
        if-no-files-found: error
        overwrite: true
```

The merge job runs after every shard succeeds. If you change the shard count or run multiple processes per shard, update the expected fragment paths and upload all of them. Set a distinct `TEST_ENV_NUMBER` per process within each shard. Only the final artifact uses the configured `map_artifact_name` and contains a single merged map.
