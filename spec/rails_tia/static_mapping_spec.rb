RSpec.describe RailsTia::StaticMapping do
  let(:rules) do
    [
      { 'source' => 'app/(models|jobs)/(.+)\.rb', 'test' => 'spec/%s/%s_spec.rb' },
      { 'source' => 'app/controllers/(.+)_controller\.rb', 'test' => 'spec/requests/%s_request_spec.rb' },
      { 'source' => 'app/views/([^/]+)/.+', 'test' => ['spec/requests/%s_request_spec.rb'] },
    ]
  end

  it '命名規約どおりのspecを引ける' do
    with_project(%w(spec/models/user_spec.rb spec/jobs/import_job_spec.rb)) do |root|
      mapping = described_class.new(rules, root: root)

      expect(mapping.specs_for('app/models/user.rb')).to eq %w(spec/models/user_spec.rb)
      expect(mapping.specs_for('app/jobs/import_job.rb')).to eq %w(spec/jobs/import_job_spec.rb)
    end
  end

  it 'ネストしたパスも引ける' do
    with_project(%w(spec/models/v2/sell_case_spec.rb)) do |root|
      mapping = described_class.new(rules, root: root)

      expect(mapping.specs_for('app/models/v2/sell_case.rb')).to eq %w(spec/models/v2/sell_case_spec.rb)
    end
  end

  it 'controllerからrequest specを引ける' do
    with_project(%w(spec/requests/api/v2/users_request_spec.rb)) do |root|
      mapping = described_class.new(rules, root: root)

      expect(mapping.specs_for('app/controllers/api/v2/users_controller.rb'))
        .to eq %w(spec/requests/api/v2/users_request_spec.rb)
    end
  end

  it 'カバレッジに現れないビューを、そのディレクトリのrequest specに対応づけられる' do
    with_project(%w(spec/requests/sell_cases_request_spec.rb)) do |root|
      mapping = described_class.new(rules, root: root)

      expect(mapping.specs_for('app/views/sell_cases/index.html.haml'))
        .to eq %w(spec/requests/sell_cases_request_spec.rb)
    end
  end

  it '解決先が実在しない場合は捨てる（単複の揺れやタイポによる誤変換を落とすため）' do
    with_project(%w(spec/requests/frequently_search_keywords_request_spec.rb)) do |root|
      mapping = described_class.new(rules, root: root)

      # A singular controller name maps only to a nonexistent singular spec, so no target is returned.
      expect(mapping.specs_for('app/controllers/api/v2/frequently_search_keyword_controller.rb')).to be_empty
    end
  end

  it '部分一致では発火しない（パターンは完全一致）' do
    with_project(%w(spec/models/user_spec.rb)) do |root|
      mapping = described_class.new(rules, root: root)

      expect(mapping.specs_for('vendor/app/models/user.rb')).to be_empty
    end
  end

  it '雛形と後方参照の数が食い違うルールは、そのルールだけ無視して続行する' do
    broken = [{ 'source' => 'app/(.+)\.rb', 'test' => 'spec/%s/%s_spec.rb' }]

    with_project(%w(spec/models/user_spec.rb)) do |root|
      mapping = described_class.new(broken + rules, root: root)

      expect { @result = mapping.specs_for('app/models/user.rb') }.to output(/static_mapping/).to_stderr
      expect(@result).to eq %w(spec/models/user_spec.rb)
    end
  end

  it '複数パスをまとめて変換できる' do
    with_project(%w(spec/models/user_spec.rb spec/jobs/import_job_spec.rb)) do |root|
      mapping = described_class.new(rules, root: root)

      expect(mapping.call(%w(app/models/user.rb app/jobs/import_job.rb app/models/unknown.rb)))
        .to match_array %w(spec/models/user_spec.rb spec/jobs/import_job_spec.rb)
    end
  end

  it 'reports absolute and parent paths in test_glob instead of selecting external specs' do
    with_project(%w[app/spec/local_spec.rb outside_spec.rb]) do |workspace|
      root = File.join(workspace, 'app')
      ['../*_spec.rb', File.join(workspace, '*_spec.rb'), '{spec,..}/*_spec.rb'].each do |glob|
        rule = { 'source' => 'frontend', 'test_glob' => glob }
        expect { described_class.new([rule], root: root).specs_for('frontend') }
          .to raise_error(described_class::InvalidGlob, /test_glob/)
      end
    end
  end

  it 'keeps internal symlinks and excludes specs reached through external file or directory symlinks' do
    with_project(%w[app/spec/local_spec.rb app-extra/external_spec.rb]) do |workspace|
      root = File.join(workspace, 'app')
      external = File.join(workspace, 'app-extra')
      File.symlink(root, File.join(workspace, 'linked-app'))
      File.symlink('local_spec.rb', File.join(root, 'spec', 'alias_spec.rb'))
      File.symlink(File.join(external, 'external_spec.rb'), File.join(root, 'spec', 'external_spec.rb'))
      File.symlink(external, File.join(root, 'linked-specs'))
      rule = { 'source' => 'frontend', 'test_glob' => ['spec/*_spec.rb', 'linked-specs/*_spec.rb'] }
      mapping = described_class.new([rule], root: File.join(workspace, 'linked-app'))

      expect(mapping.specs_for('frontend')).to contain_exactly('spec/local_spec.rb', 'spec/alias_spec.rb')
    end
  end
end
