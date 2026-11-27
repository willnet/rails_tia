require 'rails_tia/described_class_support'

RSpec.describe RailsTia::DescribedClassSupport do
  def load_source(root, path, body)
    absolute = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, body)
    load absolute
  end

  before { stub_const('DescribedTargets', Module.new) }

  it 'resolves nested classes and modules without inherited constant lookup' do
    Dir.mktmpdir do |root|
      load_source(root, 'nested.rb', 'module DescribedTargets::Nested; class Target; end; end')
      support = described_class.new(root: root)
      expect(support.files_for(DescribedTargets::Nested::Target)).to eq(['nested.rb'])
      expect(support.files_for(DescribedTargets::Nested)).to eq(['nested.rb'])
    end
  end

  it 'reuses results for the same object and resolves a replacement independently' do
    Dir.mktmpdir do |root|
      load_source(root, 'old.rb', 'class DescribedTargets::Target; end')
      original = DescribedTargets::Target
      support = described_class.new(root: root)
      first = support.files_for(original)
      expect(first).to eq(['old.rb'])
      expect(original).not_to receive(:ancestors)
      expect(support.files_for(original)).to equal(first)
      DescribedTargets.send(:remove_const, :Target)
      load_source(root, 'new.rb', 'class DescribedTargets::Target; end')
      expect(support.files_for(DescribedTargets::Target)).to eq(['new.rb'])
    end
  end

  it 'deduplicates files and reuses definition locations for shared ancestors' do
    Dir.mktmpdir do |root|
      load_source(root, 'base.rb', 'class DescribedTargets::Base; end')
      load_source(root, 'targets.rb', <<~SOURCE)
        module DescribedTargets
          class First < Base; end
          class Second < Base; end
          module Helpers; end
          Second.include(Helpers)
        end
      SOURCE
      support = described_class.new(root: root)
      expect(support.files_for(DescribedTargets::First)).to eq(%w[targets.rb base.rb])
      hide_const('DescribedTargets::Base')
      expect(support.files_for(DescribedTargets::Second)).to eq(%w[targets.rb base.rb])
    end
  end

  it 'retries a superclass lookup after a temporary replacement is restored' do
    Dir.mktmpdir do |root|
      load_source(root, 'base.rb', 'class DescribedTargets::Base; end')
      load_source(root, 'child.rb', 'class DescribedTargets::Child < DescribedTargets::Base; end')
      support = described_class.new(root: root)
      RSpec::Mocks.with_temporary_scope do
        stub_const('DescribedTargets::Base', Class.new)
        expect(support.files_for(DescribedTargets::Child)).to eq(['child.rb'])
      end
      expect(support.files_for(DescribedTargets::Child)).to eq(%w[child.rb base.rb])
    end
  end

  it 'does not resolve an old object through a different constant with the same name' do
    Dir.mktmpdir do |root|
      load_source(root, 'old.rb', 'class DescribedTargets::Target; end')
      original = DescribedTargets::Target
      DescribedTargets.send(:remove_const, :Target)
      load_source(root, 'new.rb', 'class DescribedTargets::Target; end')
      expect(described_class.new(root: root).files_for(original)).to eq([])
    end
  end

  it 'does not autoload a replacement namespace or leaf constant' do
    Dir.mktmpdir do |root|
      load_source(root, 'nested.rb', 'module DescribedTargets::Nested; class Target; end; end')
      original = DescribedTargets::Nested::Target
      DescribedTargets::Nested.send(:remove_const, :Target)
      trap = File.join(root, 'trap.rb')
      File.write(trap, "raise 'autoload triggered'")
      DescribedTargets::Nested.autoload(:Target, trap)
      support = described_class.new(root: root)
      expect(support.files_for(original)).to eq([])
      DescribedTargets.send(:remove_const, :Nested)
      DescribedTargets.autoload(:Nested, trap)
      expect(described_class.new(root: root).files_for(original)).to eq([])
    end
  end

  it 'skips unresolved, anonymous, built-in, and external targets' do
    Dir.mktmpdir do |root|
      # A sibling directory sharing the root prefix must still be external.
      Dir.mktmpdir(File.basename(root)) do |external|
        load_source(external, 'outside.rb', 'class DescribedTargets::Outside; end')
        load_source(root, 'removed.rb', 'class DescribedTargets::Removed; end')
        removed = DescribedTargets::Removed
        DescribedTargets.send(:remove_const, :Removed)
        support = described_class.new(root: root)
        [nil, 'description', 42, Class.new, Module.new, String, DescribedTargets::Outside, removed].each do |target|
          expect(support.files_for(target)).to eq([])
        end
      end
    end
  end
end
